import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';
import { VpcConstruct } from '../constructs/vpc-construct';

/**
 * Network Stackのプロパティ
 */
export interface NetworkStackProps extends cdk.StackProps {
    /** プロジェクト名 */
    readonly projectName: string;
    /** 環境名 */
    readonly environment: string;
    /** VPC CIDR */
    readonly vpcCidr: string;
}

/**
 * Network Stack
 * チーム共有のネットワークリソースを管理
 * - VPC
 * - Public Subnet
 * - Internet Gateway
 */
export class NetworkStack extends cdk.Stack {
    /** VPC */
    public readonly vpc: ec2.IVpc;
    /** VPC ID */
    public readonly vpcId: string;
    /** Public Subnet ID */
    public readonly publicSubnetId: string;

    constructor(scope: Construct, id: string, props: NetworkStackProps) {
        super(scope, id, props);

        // VPC Construct
        const vpcConstruct = new VpcConstruct(this, 'VpcConstruct', {
            vpcCidr: props.vpcCidr,
            projectName: props.projectName,
            environment: props.environment,
        });

        this.vpc = vpcConstruct.vpc;
        this.vpcId = vpcConstruct.vpc.vpcId;
        this.publicSubnetId = vpcConstruct.publicSubnet.subnetId;

        // Output: VPC ID
        new cdk.CfnOutput(this, 'VpcIdOutput', {
            value: this.vpcId,
            description: 'VPC ID',
            exportName: `${props.projectName}-${props.environment}-vpc-id`,
        });

        // Output: Public Subnet ID
        new cdk.CfnOutput(this, 'PublicSubnetIdOutput', {
            value: this.publicSubnetId,
            description: 'Public Subnet ID',
            exportName: `${props.projectName}-${props.environment}-public-subnet-id`,
        });
    }
}
