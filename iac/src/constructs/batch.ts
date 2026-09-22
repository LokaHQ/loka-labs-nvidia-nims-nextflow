import { Construct } from "constructs";
import { Stack } from "aws-cdk-lib";
import {
  AllocationStrategy,
  EcsMachineImageType,
  JobQueue,
  ManagedEc2EcsComputeEnvironment,
} from "aws-cdk-lib/aws-batch";
import {
  BlockDeviceVolume,
  EbsDeviceVolumeType,
  InstanceType,
  LaunchTemplate,
  MultipartBody,
  MultipartUserData,
  SecurityGroup,
  SelectedSubnets,
  UserData,
  Vpc,
} from "aws-cdk-lib/aws-ec2";
import { ManagedPolicy, Role, ServicePrincipal } from "aws-cdk-lib/aws-iam";

import { BatchConfig, QueueConfig } from "../config";

export interface PipelineBatchProps {
  readonly config: BatchConfig;
  readonly vpc: Vpc;
  readonly subnets: SelectedSubnets;
  readonly securityGroup: SecurityGroup;
  readonly namePrefix: string;
}

export class PipelineBatch extends Construct {
  public readonly cpuSmallQueue: JobQueue;
  public readonly gpuStandardQueue: JobQueue;
  public readonly gpuHighmemQueue: JobQueue;

  public readonly instanceRole: Role;

  public readonly jobRole: Role;

  constructor(scope: Construct, id: string, props: PipelineBatchProps) {
    super(scope, id);

    const { config } = props;

    this.instanceRole = new Role(this, "InstanceRole", {
      assumedBy: new ServicePrincipal("ec2.amazonaws.com"),
      description: "Batch container instances for the protein design pipeline",
      managedPolicies: [
        ManagedPolicy.fromAwsManagedPolicyName("service-role/AmazonEC2ContainerServiceforEC2Role"),
        ManagedPolicy.fromAwsManagedPolicyName("CloudWatchAgentServerPolicy"),
        ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"),
      ],
    });

    this.jobRole = new Role(this, "JobRole", {
      assumedBy: new ServicePrincipal("ecs-tasks.amazonaws.com"),
      description: "Protein design pipeline tasks - S3 staging identity",
    });

    this.cpuSmallQueue = this.createQueue("CpuSmall", config.cpuSmall, props);
    this.gpuStandardQueue = this.createQueue("GpuStandard", config.gpuStandard, props);
    this.gpuHighmemQueue = this.createQueue("GpuHighmem", config.gpuHighmem, props);
  }

  /** Spot compute environment + On-Demand fallback, fronted by one queue. */
  private createQueue(id: string, queueConfig: QueueConfig, props: PipelineBatchProps): JobQueue {
    const launchTemplate = this.createLaunchTemplate(id, queueConfig);

    const spot = this.createComputeEnvironment(`${id}SpotComputeEnvironment`, queueConfig, props, launchTemplate, {
      spot: true,
      maxvCpus: queueConfig.spotMaxvCpus,
    });

    const onDemand = this.createComputeEnvironment(
      `${id}OnDemandComputeEnvironment`,
      queueConfig,
      props,
      launchTemplate,
      { spot: false, maxvCpus: queueConfig.onDemandMaxvCpus },
    );

    return new JobQueue(this, `${id}Queue`, {
      jobQueueName: `${props.namePrefix}-${queueConfig.name}`,
      priority: 10,
      computeEnvironments: [
        { computeEnvironment: spot, order: 1 },
        { computeEnvironment: onDemand, order: 2 },
      ],
    });
  }

  private createLaunchTemplate(id: string, queueConfig: QueueConfig): LaunchTemplate {
    const commands = UserData.forLinux();
    commands.addCommands(
      "set -euxo pipefail",
      "( yum install -y unzip || dnf install -y unzip )",
      'curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip',
      "unzip -q -o /tmp/awscliv2.zip -d /tmp",
      "/tmp/aws/install --bin-dir /opt/aws-cli/bin --install-dir /opt/aws-cli/aws-cli --update",
      "rm -rf /tmp/aws /tmp/awscliv2.zip",
    );

    const userData = new MultipartUserData();
    userData.addUserDataPart(commands, MultipartBody.SHELL_SCRIPT, true);

    return new LaunchTemplate(this, `${id}LaunchTemplate`, {
      launchTemplateName: `${Stack.of(this).stackName}-${queueConfig.name}`,
      requireImdsv2: true,
      userData,
      blockDevices: [
        {
          deviceName: "/dev/xvda",
          volume: BlockDeviceVolume.ebs(queueConfig.volumeSizeGb, {
            volumeType: EbsDeviceVolumeType.GP3,
            encrypted: true,
            deleteOnTermination: true,
            throughput: queueConfig.volumeThroughputMibps,
            iops: queueConfig.volumeIops,
          }),
        },
      ],
    });
  }

  private createComputeEnvironment(
    id: string,
    queueConfig: QueueConfig,
    props: PipelineBatchProps,
    launchTemplate: LaunchTemplate,
    capacity: { spot: boolean; maxvCpus: number },
  ): ManagedEc2EcsComputeEnvironment {
    return new ManagedEc2EcsComputeEnvironment(this, id, {
      vpc: props.vpc,
      vpcSubnets: props.subnets,
      securityGroups: [props.securityGroup],
      instanceRole: this.instanceRole,
      launchTemplate,
      images: [
        {
          imageType: queueConfig.gpu ? EcsMachineImageType.ECS_AL2023_NVIDIA : EcsMachineImageType.ECS_AL2023,
        },
      ],
      useOptimalInstanceClasses: false,
      instanceTypes: queueConfig.instanceTypes.map((type) => new InstanceType(type)),
      minvCpus: 0,
      maxvCpus: capacity.maxvCpus,
      spot: capacity.spot,
      ...(capacity.spot && queueConfig.spotBidPercentage !== undefined
        ? { spotBidPercentage: queueConfig.spotBidPercentage }
        : {}),
      allocationStrategy: AllocationStrategy.BEST_FIT_PROGRESSIVE,
      updateToLatestImageVersion: true,
    });
  }
}
