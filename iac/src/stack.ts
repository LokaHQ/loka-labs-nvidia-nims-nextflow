import { Construct } from "constructs";
import { CfnOutput, Stack, StackProps, Tags } from "aws-cdk-lib";

import { Config, config as defaultConfig } from "./config";
import { PipelineBatch } from "./constructs/batch";
import { PipelineNetwork } from "./constructs/network";
import { ContainerRegistry } from "./constructs/registry";
import { PipelineStorage } from "./constructs/storage";

export interface NvidiaNimsStackProps extends StackProps {
  readonly config?: Config;
}

export class NvidiaNimsStack extends Stack {
  public readonly network: PipelineNetwork;
  public readonly storage: PipelineStorage;
  public readonly registry: ContainerRegistry;
  public readonly batch: PipelineBatch;

  constructor(scope: Construct, id: string, props?: NvidiaNimsStackProps) {
    super(scope, id, props);

    const config = props?.config ?? defaultConfig;

    this.network = new PipelineNetwork(this, "Network", { config: config.network });

    this.storage = new PipelineStorage(this, "Storage", { config: config.storage, namePrefix: config.project });

    this.registry = new ContainerRegistry(this, "Registry", {
      config: config.registry,
      namespace: config.project,
    });

    this.batch = new PipelineBatch(this, "Batch", {
      config: config.batch,
      vpc: this.network.vpc,
      subnets: this.network.computeSubnets,
      securityGroup: this.network.securityGroup,
      namePrefix: config.project,
    });

    this.storage.grantPipelineAccess(this.batch.jobRole);
    this.storage.grantPipelineAccess(this.batch.instanceRole);
    this.registry.grantPullPush(this.batch.instanceRole);
    this.storage.restrictAccessTo([this.batch.jobRole, this.batch.instanceRole]);

    this.addOutputs();

    Tags.of(this).add("Project", config.project);
    Tags.of(this).add("Team", config.team);
    Tags.of(this).add("GitRepository", config.gitRepository);
  }

  private addOutputs(): void {
    new CfnOutput(this, "InputBucket", {
      value: this.storage.inputBucket.bucketName,
      description: "params.input_bucket - task inputs",
    });

    new CfnOutput(this, "WorkdirBucket", {
      value: this.storage.workdirBucket.bucketName,
      description: "workDir - the Nextflow work directory",
    });

    new CfnOutput(this, "OutputBucket", {
      value: this.storage.outputBucket.bucketName,
      description: "params.output_bucket - publishDir target",
    });

    new CfnOutput(this, "CpuSmallQueue", {
      value: this.batch.cpuSmallQueue.jobQueueName,
      description: "params.cpu_small_queue - ProteinMPNN no-NIM",
    });

    new CfnOutput(this, "GpuStandardQueue", {
      value: this.batch.gpuStandardQueue.jobQueueName,
      description: "params.gpu_standard_queue - RFdiffusion, ProteinMPNN NIM, AF2 no-NIM",
    });

    new CfnOutput(this, "GpuHighmemQueue", {
      value: this.batch.gpuHighmemQueue.jobQueueName,
      description: "params.gpu_highmem_queue - AF2 NIM",
    });

    new CfnOutput(this, "JobRoleArn", {
      value: this.batch.jobRole.roleArn,
      description: "aws.batch.jobRole - the identity the bucket policies are scoped to",
    });

    new CfnOutput(this, "EcrRegistry", {
      value: `${this.account}.dkr.ecr.${this.region}.amazonaws.com`,
      description: "params.ecr_registry",
    });

    new CfnOutput(this, "EcrRepository", {
      value: this.registry.repository.repositoryName,
      description: "params.ecr_repository - one shared repository, images tagged <tool>-<version>",
    });
  }
}
