import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Construct } from 'constructs';

/**
 * VPC Constructのプロパティ
 */
export interface VpcConstructProps {
  /** VPC CIDR */
  readonly vpcCidr: string;
  /** プロジェクト名（リソース命名に使用） */
  readonly projectName: string;
  /** 環境名 */
  readonly environment: string;
}

/**
 * VPC Construct
 * Public Subnetのみを持つシンプルなVPCを作成
 * - NAT Gatewayは使用しない（コスト削減）
 * - Internet Gateway経由で外部通信
 */
export class VpcConstruct extends Construct {
  /** 作成されたVPC */
  public readonly vpc: ec2.IVpc;
  /** Public Subnet */
  public readonly publicSubnet: ec2.ISubnet;

  constructor(scope: Construct, id: string, props: VpcConstructProps) {
    super(scope, id);

    // VPC作成（Public Subnetのみ、NAT Gatewayなし）
    this.vpc = new ec2.Vpc(this, 'Vpc', {
      ipAddresses: ec2.IpAddresses.cidr(props.vpcCidr),
      maxAzs: 1, // 開発環境なので1 AZで十分
      natGateways: 0, // NAT Gatewayは使用しない（コスト削減）
      subnetConfiguration: [
        {
          name: 'Public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24,
        },
      ],
      // VPCフローログ（オプション：セキュリティ監査用）
      // flowLogs: {
      //   'FlowLog': {
      //     trafficType: ec2.FlowLogTrafficType.ALL,
      //   },
      // },
    });

    // Public Subnetを取得
    this.publicSubnet = this.vpc.publicSubnets[0];

    // タグ付け
    cdk.Tags.of(this.vpc).add('Name', `${props.projectName}-${props.environment}-vpc`);
    cdk.Tags.of(this.vpc).add('Project', props.projectName);
    cdk.Tags.of(this.vpc).add('Environment', props.environment);
  }
}
