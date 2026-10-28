import { Construct } from "constructs";
import { RemovalPolicy } from "aws-cdk-lib";
import { Port, SecurityGroup, SelectedSubnets, Vpc } from "aws-cdk-lib/aws-ec2";
import { LustreDeploymentType, LustreFileSystem } from "aws-cdk-lib/aws-fsx";

import { MsaCacheConfig } from "../config";

export interface MsaCacheProps {
  readonly config: MsaCacheConfig;
  readonly vpc: Vpc;
  readonly subnets: SelectedSubnets;
  readonly computeSecurityGroup: SecurityGroup;
}

/**
 * FSx for Lustre holding the ColabFold MSA databases, shared by every Batch
 * instance. Nothing is created while `config.enabled` is false.
 */
export class MsaCache extends Construct {
  public readonly fileSystem?: LustreFileSystem;

  constructor(scope: Construct, id: string, props: MsaCacheProps) {
    super(scope, id);

    const { config, vpc, subnets, computeSecurityGroup } = props;

    if (!config.enabled) {
      return;
    }

    const [vpcSubnet] = subnets.subnets;
    if (!vpcSubnet) {
      throw new Error("MsaCache needs at least one compute subnet");
    }

    const securityGroup = new SecurityGroup(this, "SecurityGroup", {
      vpc,
      description: "FSx for Lustre holding the MSA databases",
      allowAllOutbound: true,
    });

    // Lustre uses 988 for the management service and 1018-1023 for the data
    // connections; both directions are needed between client and server.
    for (const port of [Port.tcp(988), Port.tcpRange(1018, 1023)]) {
      securityGroup.addIngressRule(computeSecurityGroup, port, "Lustre from Batch instances");
      computeSecurityGroup.addIngressRule(securityGroup, port, "Lustre from the FSx filesystem");
    }

    this.fileSystem = new LustreFileSystem(this, "FileSystem", {
      vpc,
      // A Lustre filesystem lives in exactly one subnet, so every instance that
      // mounts it pays cross-AZ traffic unless it lands in the same AZ.
      vpcSubnet,
      securityGroup,
      storageCapacityGiB: config.storageCapacityGb,
      lustreConfiguration: {
        // SCRATCH_2 has no replication and no backups. Correct here: the
        // contents are public databases that can be downloaded again.
        deploymentType: LustreDeploymentType.SCRATCH_2,
      },
      // The whole point is that it goes away when disabled.
      removalPolicy: RemovalPolicy.DESTROY,
    });
  }
}
