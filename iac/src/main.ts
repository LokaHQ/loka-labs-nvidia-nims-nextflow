import * as cdk from "aws-cdk-lib";

import { NvidiaNimsStack } from "./stack";

const app = new cdk.App();

new NvidiaNimsStack(app, "NvidiaNimsBatch", {
  env: {
    account: process.env["CDK_DEFAULT_ACCOUNT"],
    region: process.env["CDK_DEFAULT_REGION"] ?? "us-east-1",
  },
});
