import { Construct } from "constructs";
import {
  GatewayVpcEndpointAwsService,
  InterfaceVpcEndpointAwsService,
  IpAddresses,
  Peer,
  Port,
  SecurityGroup,
  SubnetType,
  Vpc,
} from "aws-cdk-lib/aws-ec2";

import { NetworkConfig } from "../config";

export interface PipelineNetworkProps {
  readonly config: NetworkConfig;
}


export class PipelineNetwork extends Construct {
  public readonly vpc: Vpc;
  public readonly securityGroup: SecurityGroup;

  constructor(scope: Construct, id: string, props: PipelineNetworkProps) {
    super(scope, id);

    const { config } = props;

    this.vpc = new Vpc(this, "Vpc", {
      ipAddresses: IpAddresses.cidr(config.cidr),
      maxAzs: config.maxAzs,
      natGateways: config.natGateways,
      restrictDefaultSecurityGroup: true,
      subnetConfiguration: [
        {
          name: "public",
          subnetType: SubnetType.PUBLIC,
          cidrMask: 24,
          mapPublicIpOnLaunch: false,
        },
        {
          name: "private",
          subnetType: SubnetType.PRIVATE_WITH_EGRESS,
          cidrMask: 19,
        },
      ],
    });

    this.vpc.addGatewayEndpoint("S3Endpoint", {
      service: GatewayVpcEndpointAwsService.S3,
    });

    const interfaceEndpoints = {
      EcrApiEndpoint: InterfaceVpcEndpointAwsService.ECR,
      EcrDockerEndpoint: InterfaceVpcEndpointAwsService.ECR_DOCKER,
      CloudWatchLogsEndpoint: InterfaceVpcEndpointAwsService.CLOUDWATCH_LOGS,
    };

    for (const [endpointId, service] of Object.entries(interfaceEndpoints)) {
      this.vpc.addInterfaceEndpoint(endpointId, {
        service,
        privateDnsEnabled: true,
        subnets: { subnetType: SubnetType.PRIVATE_WITH_EGRESS },
      });
    }

    this.securityGroup = new SecurityGroup(this, "ComputeSecurityGroup", {
      vpc: this.vpc,
      description: "Batch container instances running pipeline tasks",
      allowAllOutbound: true,
    });

    this.securityGroup.addIngressRule(
      Peer.ipv4(this.vpc.vpcCidrBlock),
      Port.tcp(443),
      "HTTPS within the VPC (VPC endpoints)",
    );
  }

  public get computeSubnets() {
    return this.vpc.selectSubnets({ subnetType: SubnetType.PRIVATE_WITH_EGRESS });
  }
}
