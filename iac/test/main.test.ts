import * as cdk from "aws-cdk-lib";
import { Match, Template } from "aws-cdk-lib/assertions";

import "jest-cdk-snapshot";
import * as fs from "node:fs";
import * as path from "node:path";

import { config } from "../src/config";
import { NvidiaNimsStack } from "../src/stack";

const env = { account: "123456789012", region: "us-east-1" };

function synth(): Template {
  const app = new cdk.App();
  const stack = new NvidiaNimsStack(app, "MyTestStack", { env });

  return Template.fromStack(stack);
}

test("snapshot for NvidiaNimsStack matches previous state", () => {
  const app = new cdk.App();
  const stack = new NvidiaNimsStack(app, "MyTestStack", { env });

  expect(stack).toMatchCdkSnapshot({
    ignoreAssets: true,
    ignoreCurrentVersion: true,
    ignoreMetadata: true,
  });
});

test("the input bucket expires objects and the output bucket is versioned", () => {
  const template = synth();
  const buckets = Object.values(template.findResources("AWS::S3::Bucket"));

  expect(buckets).toHaveLength(2);

  const input = buckets.find((bucket) => bucket.Properties?.VersioningConfiguration === undefined);
  const output = buckets.find((bucket) => bucket.Properties?.VersioningConfiguration !== undefined);

  expect(input?.Properties?.LifecycleConfiguration?.Rules).toEqual(
    expect.arrayContaining([expect.objectContaining({ ExpirationInDays: config.storage.inputExpirationDays })]),
  );
  expect(output?.Properties?.VersioningConfiguration).toEqual({ Status: "Enabled" });
  // Results must not disappear on a lifecycle rule nobody remembered adding.
  expect(
    (output?.Properties?.LifecycleConfiguration?.Rules ?? []).some(
      (rule: { ExpirationInDays?: number }) => rule.ExpirationInDays !== undefined,
    ),
  ).toBe(false);
});

test("both buckets are private, encrypted and retained", () => {
  const template = synth();
  const buckets = template.findResources("AWS::S3::Bucket");

  Object.values(buckets).forEach((bucket) => {
    expect(bucket.Properties?.PublicAccessBlockConfiguration).toEqual({
      BlockPublicAcls: true,
      BlockPublicPolicy: true,
      IgnorePublicAcls: true,
      RestrictPublicBuckets: true,
    });
    expect(bucket.Properties?.BucketEncryption).toBeDefined();
    expect(bucket.DeletionPolicy).toBe("Retain");
  });
});

test("bucket policies deny every principal outside the pipeline roles", () => {
  const template = synth();
  const policies = Object.values(template.findResources("AWS::S3::BucketPolicy"));

  expect(policies).toHaveLength(2);

  policies.forEach((policy) => {
    const statements = policy.Properties?.PolicyDocument?.Statement ?? [];
    const denyOthers = statements.find(
      (statement: { Sid?: string }) => statement.Sid === "DenyEveryPrincipalExceptThePipelineRoles",
    );

    expect(denyOthers).toBeDefined();
    expect(denyOthers.Effect).toBe("Deny");
    expect(denyOthers.Condition?.StringNotLike?.["aws:PrincipalArn"]).toBeDefined();
  });
});

test("one shared, scan-on-push ECR repository, expiring untagged images", () => {
  const template = synth();
  const repositories = Object.values(template.findResources("AWS::ECR::Repository"));

  expect(repositories).toHaveLength(1);
  expect(repositories[0].Properties?.RepositoryName).toBe(config.project);
  expect(repositories[0].Properties?.ImageScanningConfiguration).toEqual({ ScanOnPush: true });

  const lifecycle = JSON.parse(repositories[0].Properties?.LifecyclePolicy?.LifecyclePolicyText as string);
  expect(lifecycle.rules[0].selection).toEqual(
    expect.objectContaining({
      tagStatus: "untagged",
      countUnit: "days",
      countNumber: config.registry.untaggedImageExpirationDays,
    }),
  );
});

test("three queues, each Spot-first with an On-Demand fallback", () => {
  const template = synth();
  const queues = Object.values(template.findResources("AWS::Batch::JobQueue"));

  expect(queues).toHaveLength(3);

  const expectedNames = [config.batch.cpuSmall, config.batch.gpuStandard, config.batch.gpuHighmem].map(
    (queue) => `${config.project}-${queue.name}`,
  );
  expect(queues.map((queue) => queue.Properties?.JobQueueName as string).sort()).toEqual(expectedNames.sort());

  queues.forEach((queue) => {
    const order = queue.Properties?.ComputeEnvironmentOrder ?? [];
    // Spot at order 1, On-Demand at order 2 - a queue with a single CE has no fallback.
    expect(order.map((entry: { Order: number }) => entry.Order)).toEqual([1, 2]);
  });
});

test("every compute environment scales to zero and uses BEST_FIT_PROGRESSIVE", () => {
  const template = synth();
  const computeEnvironments = Object.values(template.findResources("AWS::Batch::ComputeEnvironment"));

  // Three queues x (Spot + On-Demand).
  expect(computeEnvironments).toHaveLength(6);

  computeEnvironments.forEach((ce) => {
    expect(ce.Properties?.ComputeResources?.MinvCpus).toBe(0);
    expect(ce.Properties?.ComputeResources?.AllocationStrategy).toBe("BEST_FIT_PROGRESSIVE");
  });

  const types = computeEnvironments.map((ce) => ce.Properties?.ComputeResources?.Type as string);
  expect(types.filter((type) => type === "SPOT")).toHaveLength(3);
  expect(types.filter((type) => type === "EC2")).toHaveLength(3);
});

test("GPU compute environments use the NVIDIA ECS AMI, the CPU one does not", () => {
  const template = synth();
  const computeEnvironments = Object.values(template.findResources("AWS::Batch::ComputeEnvironment"));

  const imageTypeOf = (ce: Record<string, any>) =>
    (ce.Properties?.ComputeResources?.Ec2Configuration ?? []).map(
      (entry: { ImageType: string }) => entry.ImageType,
    )[0] as string;

  const gpuInstanceFamilies = [...config.batch.gpuStandard.instanceTypes, ...config.batch.gpuHighmem.instanceTypes];

  computeEnvironments.forEach((ce) => {
    const instanceTypes = (ce.Properties?.ComputeResources?.InstanceTypes ?? []) as string[];
    const isGpu = instanceTypes.some((type) => gpuInstanceFamilies.includes(type));

    expect(imageTypeOf(ce)).toBe(isGpu ? "ECS_AL2_NVIDIA" : "ECS_AL2023");
  });
});

test("each queue has its own launch template and only gpu-highmem pays for the big volume", () => {
  const template = synth();
  const launchTemplates = Object.values(template.findResources("AWS::EC2::LaunchTemplate"));

  expect(launchTemplates).toHaveLength(3);

  const volumeSizes = launchTemplates
    .map((lt) => lt.Properties?.LaunchTemplateData?.BlockDeviceMappings?.[0]?.Ebs?.VolumeSize as number)
    .sort((a, b) => a - b);

  // AF2 NIM needs 1250 GB of task disk; nothing else comes close.
  expect(volumeSizes[2]).toBeGreaterThanOrEqual(1250);
  expect(volumeSizes[0]).toBeLessThan(1250);
  expect(volumeSizes[1]).toBeLessThan(1250);

  launchTemplates.forEach((lt) => {
    expect(lt.Properties?.LaunchTemplateData?.BlockDeviceMappings?.[0]?.Ebs).toEqual(
      expect.objectContaining({ Encrypted: true, VolumeType: "gp3" }),
    );
  });
});

test("S3 and ECR traffic leaves through VPC endpoints rather than the NAT gateway", () => {
  const template = synth();

  template.hasResourceProperties("AWS::EC2::VPCEndpoint", {
    VpcEndpointType: "Gateway",
    ServiceName: Match.objectLike({ "Fn::Join": Match.arrayWith([Match.arrayWith([".s3"])]) }),
  });

  const interfaceEndpoints = Object.values(template.findResources("AWS::EC2::VPCEndpoint")).filter(
    (endpoint) => endpoint.Properties?.VpcEndpointType === "Interface",
  );

  // ECR API, ECR DKR, CloudWatch Logs.
  expect(interfaceEndpoints).toHaveLength(3);
});

test("existing subnets are not replaced (CIDR blocks unchanged)", () => {
  const template = synth();

  const subnets = template.findResources("AWS::EC2::Subnet");

  // Create a map of logical ID -> CIDR block
  const currentSubnets: Record<string, string> = {};
  Object.entries(subnets).forEach(([logicalId, resource]) => {
    currentSubnets[logicalId] = resource.Properties?.CidrBlock as string;
  });

  const snapshotPath = path.join(__dirname, "__snapshots__", "subnet-cidrs.json");

  // Initialize if doesn't exist
  if (!fs.existsSync(snapshotPath)) {
    fs.mkdirSync(path.dirname(snapshotPath), { recursive: true });
    fs.writeFileSync(snapshotPath, JSON.stringify(currentSubnets, null, 2));
    console.log(`✓ Created baseline: ${snapshotPath}`);
    return;
  }

  const baselineSubnets: Record<string, string> = JSON.parse(fs.readFileSync(snapshotPath, "utf-8"));

  // Check if any existing subnet's CIDR changed (indicates replacement)
  const changedSubnets: string[] = [];
  Object.entries(baselineSubnets).forEach(([logicalId, cidr]) => {
    if (currentSubnets[logicalId] && currentSubnets[logicalId] !== cidr) {
      changedSubnets.push(`  ${logicalId}: ${cidr} → ${currentSubnets[logicalId]}`);
    }
  });

  // Check for missing subnets (deleted logical IDs)
  const missingSubnets = Object.keys(baselineSubnets).filter((id) => !currentSubnets[id]);

  if (changedSubnets.length > 0 || missingSubnets.length > 0) {
    let errorMsg = `🚨 SUBNET REPLACEMENT DETECTED 🚨\n\n`;

    if (changedSubnets.length > 0) {
      errorMsg += `CIDR blocks changed (requires replacement):\n${changedSubnets.join("\n")}\n\n`;
    }

    if (missingSubnets.length > 0) {
      errorMsg += `Missing subnets:\n${missingSubnets.map((id) => `  - ${id}`).join("\n")}\n\n`;
    }

    errorMsg += `Common causes:\n`;
    errorMsg += `  1. Inserting new subnets in the middle of subnetConfiguration array\n`;
    errorMsg += `  2. Reordering existing subnets\n`;
    errorMsg += `Solution: Always ADD new subnets at the END of the array.\n\n`;
    errorMsg += `If this change is intentional, delete the baseline and regenerate:\n`;
    errorMsg += `  rm ${snapshotPath}\n`;
    errorMsg += `  yarn test\n`;

    throw new Error(errorMsg);
  }

  // Auto-update with new additions
  const newSubnets = Object.keys(currentSubnets).filter((id) => !baselineSubnets[id]);

  if (newSubnets.length > 0) {
    console.log(`✓ New subnets detected (safe additions):`);
    newSubnets.forEach((id) => {
      console.log(`    ${id}: ${currentSubnets[id]}`);
    });

    fs.writeFileSync(snapshotPath, JSON.stringify(currentSubnets, null, 2));
    console.log(`✓ Updated: ${snapshotPath}`);
  }
});
