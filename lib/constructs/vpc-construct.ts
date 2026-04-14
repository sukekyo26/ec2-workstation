import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as iam from 'aws-cdk-lib/aws-iam';
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
  /**
   * VPC Flow Logsを有効にするか
   * @default true
   */
  readonly enableFlowLogs?: boolean;
  /**
   * Flow Logsで記録するトラフィックタイプ
   * - ALL: 全トラフィック
   * - ACCEPT: 許可されたトラフィック
   * - REJECT: 拒否されたトラフィック（セキュリティ監査向け）
   * @default REJECT
   */
  readonly flowLogTrafficType?: ec2.FlowLogTrafficType;
}

/**
 * VPC Construct
 * Public Subnetのみを持つシンプルなVPCを作成
 * - NAT Gatewayは使用しない（コスト削減）
 * - Internet Gateway経由で外部通信
 * - VPC Flow Logsでセキュリティ監査対応
 */
export class VpcConstruct extends Construct {
  /** 作成されたVPC */
  public readonly vpc: ec2.IVpc;
  /** Public Subnet */
  public readonly publicSubnet: ec2.ISubnet;
  /** VPC Flow Logs用ロググループ（有効な場合） */
  public readonly flowLogGroup?: logs.ILogGroup;

  constructor(scope: Construct, id: string, props: VpcConstructProps) {
    super(scope, id);

    const enableFlowLogs = props.enableFlowLogs ?? true;
    const flowLogTrafficType = props.flowLogTrafficType ?? ec2.FlowLogTrafficType.REJECT;
    const resourcePrefix = `${props.projectName}-${props.environment}`;

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
    });

    // Public Subnetを取得
    this.publicSubnet = this.vpc.publicSubnets[0];

    // ============================================================
    // VPC Flow Logs
    // ============================================================
    if (enableFlowLogs) {
      // Flow Logs用CloudWatch Logsグループ
      this.flowLogGroup = new logs.LogGroup(this, 'FlowLogGroup', {
        logGroupName: `/vpc/flow-logs/${resourcePrefix}`,
        retention: logs.RetentionDays.ONE_MONTH,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
      });

      // Flow Logs用IAMロール
      const flowLogRole = new iam.Role(this, 'FlowLogRole', {
        roleName: `${resourcePrefix}-flow-log-role`,
        assumedBy: new iam.ServicePrincipal('vpc-flow-logs.amazonaws.com'),
        description: 'IAM role for VPC Flow Logs',
      });

      // CloudWatch Logsへの書き込み権限
      this.flowLogGroup.grantWrite(flowLogRole);

      // VPC Flow Logsを有効化
      new ec2.FlowLog(this, 'FlowLog', {
        resourceType: ec2.FlowLogResourceType.fromVpc(this.vpc),
        destination: ec2.FlowLogDestination.toCloudWatchLogs(
          this.flowLogGroup,
          flowLogRole
        ),
        trafficType: flowLogTrafficType,
        flowLogName: `${resourcePrefix}-flow-log`,
      });

      // タグ付け
      cdk.Tags.of(this.flowLogGroup).add('Name', `${resourcePrefix}-flow-log-group`);
      cdk.Tags.of(this.flowLogGroup).add('Project', props.projectName);
      cdk.Tags.of(this.flowLogGroup).add('Environment', props.environment);
    }

    // タグ付け
    cdk.Tags.of(this.vpc).add('Name', `${resourcePrefix}-vpc`);
    cdk.Tags.of(this.vpc).add('Project', props.projectName);
    cdk.Tags.of(this.vpc).add('Environment', props.environment);
  }
}
