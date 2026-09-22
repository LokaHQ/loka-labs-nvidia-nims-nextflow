import { Construct } from "constructs";
import { Duration, RemovalPolicy } from "aws-cdk-lib";
import { Repository, TagMutability, TagStatus } from "aws-cdk-lib/aws-ecr";
import { IGrantable } from "aws-cdk-lib/aws-iam";

import { RegistryConfig } from "../config";

export interface ContainerRegistryProps {
  readonly config: RegistryConfig;
  readonly namespace: string;
}


export class ContainerRegistry extends Construct {
  public readonly repository: Repository;

  constructor(scope: Construct, id: string, props: ContainerRegistryProps) {
    super(scope, id);

    const { config, namespace } = props;

    this.repository = new Repository(this, "Repository", {
      repositoryName: namespace,
      imageScanOnPush: true,
      imageTagMutability: TagMutability.MUTABLE,
      emptyOnDelete: false,
      removalPolicy: RemovalPolicy.RETAIN,
      lifecycleRules: [
        {
          description: "Expire untagged images",
          tagStatus: TagStatus.UNTAGGED,
          maxImageAge: Duration.days(config.untaggedImageExpirationDays),
        },
      ],
    });
  }

  public grantPull(grantee: IGrantable): void {
    this.repository.grantPull(grantee);
  }

  public grantPullPush(grantee: IGrantable): void {
    this.repository.grantPullPush(grantee);
  }
}
