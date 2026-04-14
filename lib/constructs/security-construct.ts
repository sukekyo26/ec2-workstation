import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';

/**
 * Security Constructのプロパティ
 */
export interface SecurityConstructProps {
    /** VPC */
    readonly vpc: ec2.IVpc;
    /** プロジェクト名 */
    readonly projectName: string;
    /** 環境名 */
    readonly environment: string;
    /** ユーザー名（個人用リソース識別） */
    readonly username: string;
}

/**
 * Security Construct
 * セキュリティグループとIAMロールを作成
 * - 全インバウンドをブロック（SSH含む）
 * - アウトバウンドはHTTPS(443)のみ許可
 * - SSM接続に必要な最小限のIAM権限
 */
export class SecurityConstruct extends Construct {
    /** EC2用セキュリティグループ */
    public readonly securityGroup: ec2.ISecurityGroup;
    /** EC2用IAMロール */
    public readonly instanceRole: iam.IRole;
    /** EC2用インスタンスプロファイル */
    public readonly instanceProfile: iam.InstanceProfile;
    /** SessionManagerログ用CloudWatch Logsグループ */
    public readonly sessionLogGroup: logs.ILogGroup;

    constructor(scope: Construct, id: string, props: SecurityConstructProps) {
        super(scope, id);

        const resourcePrefix = `${props.projectName}-${props.environment}-${props.username}`;

        // セキュリティグループ作成
        this.securityGroup = new ec2.SecurityGroup(this, 'SecurityGroup', {
            vpc: props.vpc,
            securityGroupName: `${resourcePrefix}-sg`,
            description: `Security group for ${props.username} workspace - All inbound blocked`,
            allowAllOutbound: false, // アウトバウンドも明示的に制御
        });

        // アウトバウンドルール: HTTPS(443)のみ許可
        // - SSM Endpoints (ssm.ap-northeast-1.amazonaws.com, etc.)
        // - GitHub (github.com)
        // - Docker Hub (hub.docker.com, registry-1.docker.io)
        // - パッケージリポジトリ (archive.ubuntu.com, etc.)
        this.securityGroup.addEgressRule(
            ec2.Peer.anyIpv4(),
            ec2.Port.tcp(443),
            'Allow HTTPS outbound for SSM, git, docker, apt'
        );

        // HTTP(80)も許可（一部のパッケージリポジトリ用）
        this.securityGroup.addEgressRule(
            ec2.Peer.anyIpv4(),
            ec2.Port.tcp(80),
            'Allow HTTP outbound for package repositories'
        );

        // DNS解決用（VPC DNSサーバー）
        this.securityGroup.addEgressRule(
            ec2.Peer.anyIpv4(),
            ec2.Port.udp(53),
            'Allow DNS resolution'
        );

        // インバウンドルールは追加しない（デフォルトで全てブロック）
        // SSH (22) も含めて全ての外部からの接続を拒否

        // SessionManagerログ用CloudWatch Logsグループ
        this.sessionLogGroup = new logs.LogGroup(this, 'SessionLogGroup', {
            logGroupName: `/ssm/session-logs/${resourcePrefix}`,
            retention: logs.RetentionDays.ONE_MONTH,
            removalPolicy: cdk.RemovalPolicy.DESTROY,
        });

        // EC2用IAMロール作成
        this.instanceRole = new iam.Role(this, 'InstanceRole', {
            roleName: `${resourcePrefix}-instance-role`,
            assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
            description: `IAM role for ${props.username} workspace EC2 instance`,
        });

        // SSM接続に必要な権限を付与
        // AmazonSSMManagedInstanceCore: SSM Agent基本権限
        this.instanceRole.addManagedPolicy(
            iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore')
        );

        // CloudWatch Logsへのセッションログ書き込み権限
        this.sessionLogGroup.grantWrite(this.instanceRole);

        // S3へのアクセス権限（SSMセッションログ用、オプション）
        // 必要に応じてS3バケットを追加

        // インスタンスプロファイル作成
        this.instanceProfile = new iam.InstanceProfile(this, 'InstanceProfile', {
            instanceProfileName: `${resourcePrefix}-instance-profile`,
            role: this.instanceRole,
        });

        // タグ付け
        cdk.Tags.of(this.securityGroup).add('Name', `${resourcePrefix}-sg`);
        cdk.Tags.of(this.securityGroup).add('Owner', props.username);
        cdk.Tags.of(this.instanceRole).add('Owner', props.username);
    }
}
