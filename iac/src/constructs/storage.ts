import { Construct } from "constructs";
import { Duration, RemovalPolicy, Stack } from "aws-cdk-lib";
import { AnyPrincipal, Effect, IGrantable, IRole, PolicyStatement } from "aws-cdk-lib/aws-iam";
import { BlockPublicAccess, Bucket, BucketEncryption } from "aws-cdk-lib/aws-s3";

import { StorageConfig } from "../config";

export interface PipelineStorageProps {
  readonly config: StorageConfig;
  readonly namePrefix: string;
}

export class PipelineStorage extends Construct {
  public readonly inputBucket: Bucket;
  public readonly workdirBucket: Bucket;
  public readonly outputBucket: Bucket;

  private readonly config: StorageConfig;

  constructor(scope: Construct, id: string, props: PipelineStorageProps) {
    super(scope, id);

    this.config = props.config;
    const { namePrefix } = props;

    this.inputBucket = new Bucket(this, "InputBucket", {
      bucketName: `${namePrefix}-input`,
      encryption: BucketEncryption.S3_MANAGED,
      blockPublicAccess: BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      versioned: false,
      lifecycleRules: [
        {
          id: "expire-inputs",
          expiration: Duration.days(this.config.inputExpirationDays),
          abortIncompleteMultipartUploadAfter: Duration.days(7),
        },
      ],
      removalPolicy: RemovalPolicy.RETAIN,
    });

    this.workdirBucket = new Bucket(this, "WorkdirBucket", {
      bucketName: `${namePrefix}-workdir`,
      encryption: BucketEncryption.S3_MANAGED,
      blockPublicAccess: BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      versioned: false,
      lifecycleRules: [
        {
          id: "expire-workdir",
          expiration: Duration.days(this.config.workdirExpirationDays),
          abortIncompleteMultipartUploadAfter: Duration.days(7),
        },
      ],
      removalPolicy: RemovalPolicy.RETAIN,
    });

    this.outputBucket = new Bucket(this, "OutputBucket", {
      bucketName: `${namePrefix}-output`,
      encryption: BucketEncryption.S3_MANAGED,
      blockPublicAccess: BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      versioned: true,
      lifecycleRules: [{ id: "abort-incomplete-uploads", abortIncompleteMultipartUploadAfter: Duration.days(7) }],
      removalPolicy: RemovalPolicy.RETAIN,
    });
  }

  public grantPipelineAccess(grantee: IGrantable): void {
    this.inputBucket.grantReadWrite(grantee);
    this.workdirBucket.grantReadWrite(grantee);
    this.outputBucket.grantReadWrite(grantee);
  }


  public restrictAccessTo(roles: readonly IRole[]): void {
    if (!this.config.restrictToJobRole) {
      return;
    }

    const { account } = Stack.of(this);

    const allowedPrincipalArns = [
      ...roles.map((role) => role.roleArn),
      `arn:aws:iam::${account}:root`,
      `arn:aws:iam::${account}:role/cdk-*`,
      ...this.config.additionalPrincipalArns,
    ];

    for (const bucket of [this.inputBucket, this.workdirBucket, this.outputBucket]) {
      bucket.addToResourcePolicy(
        new PolicyStatement({
          sid: "DenyEveryPrincipalExceptThePipelineRoles",
          effect: Effect.DENY,
          principals: [new AnyPrincipal()],
          actions: ["s3:*"],
          resources: [bucket.bucketArn, bucket.arnForObjects("*")],
          conditions: {
            StringNotLike: { "aws:PrincipalArn": allowedPrincipalArns },
            BoolIfExists: { "aws:PrincipalIsAWSService": "false" },
          },
        }),
      );
    }
  }
}
