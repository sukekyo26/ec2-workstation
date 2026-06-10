import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';
import { InstanceConfig } from '../config/workstation-config';

/**
 * EC2 Constructのプロパティ
 */
export interface Ec2ConstructProps {
    /** VPC */
    readonly vpc: ec2.IVpc;
    /** セキュリティグループ */
    readonly securityGroup: ec2.ISecurityGroup;
    /** インスタンスプロファイル */
    readonly instanceProfile: iam.IInstanceProfile;
    /** プロジェクト名 */
    readonly projectName: string;
    /** 環境名 */
    readonly environment: string;
    /** ユーザー名 */
    readonly username: string;
    /** インスタンス設定 */
    readonly instanceConfig: InstanceConfig;
    /** User Dataスクリプト */
    readonly userData: ec2.UserData;
    /** Elastic IP を有効にするか */
    readonly enableElasticIp?: boolean;
}

/**
 * EC2 Construct
 * Ubuntu 24.04 LTSのEC2インスタンスを作成
 * - SSM Agent自動インストール
 * - Docker & Docker Compose
 * - 開発ツール一式
 */
export class Ec2Construct extends Construct {
    /** 作成されたEC2インスタンス */
    public readonly instance: ec2.Instance;
    /** インスタンスID */
    public readonly instanceId: string;
    /** SSHキーペア */
    public readonly keyPair: ec2.KeyPair;
    /** Elastic IP（有効な場合のみ） */
    public readonly elasticIp?: ec2.CfnEIP;

    constructor(scope: Construct, id: string, props: Ec2ConstructProps) {
        super(scope, id);

        const resourcePrefix = `${props.projectName}-${props.environment}-${props.username}`;

        // SSHキーペア作成（公開鍵はAWSが自動生成、秘密鍵はSSM Parameter Storeに保存）
        this.keyPair = new ec2.KeyPair(this, 'KeyPair', {
            keyPairName: `${resourcePrefix}-keypair`,
            type: ec2.KeyPairType.ED25519,
        });

        // Ubuntu 24.04 LTS AMIを取得
        const ubuntuAmi = ec2.MachineImage.lookup({
            name: 'ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*',
            owners: ['099720109477'], // Canonical
        });

        // EC2インスタンス作成
        this.instance = new ec2.Instance(this, 'Instance', {
            vpc: props.vpc,
            vpcSubnets: {
                subnetType: ec2.SubnetType.PUBLIC,
            },
            instanceType: new ec2.InstanceType(props.instanceConfig.instanceType),
            machineImage: ubuntuAmi,
            securityGroup: props.securityGroup,
            role: props.instanceProfile.role as iam.IRole,
            // インスタンスプロファイルはロール経由で自動作成されるため、
            // ここでは明示的に設定しない

            // SSHキーペア（Remote-SSH接続用）
            keyPair: this.keyPair,

            // User Data
            userData: props.userData,

            // EBS設定
            blockDevices: [
                {
                    deviceName: '/dev/sda1',
                    volume: ec2.BlockDeviceVolume.ebs(props.instanceConfig.volumeSize, {
                        volumeType: props.instanceConfig.volumeType === 'gp3'
                            ? ec2.EbsDeviceVolumeType.GP3
                            : ec2.EbsDeviceVolumeType.GP2,
                        encrypted: true, // 暗号化有効
                        deleteOnTermination: true, // インスタンス削除時にEBSも削除
                    }),
                },
            ],

            // インスタンス名
            instanceName: `${resourcePrefix}-instance`,

            // パブリックIP自動割り当て（SessionManager接続に必要）
            associatePublicIpAddress: true,

            // IMDSv2を強制（セキュリティ強化）
            requireImdsv2: true,
        });

        // インスタンスIDを保存
        this.instanceId = this.instance.instanceId;

        // タグ付け
        cdk.Tags.of(this.instance).add('Name', `${resourcePrefix}-instance`);
        cdk.Tags.of(this.instance).add('Owner', props.username);
        cdk.Tags.of(this.instance).add('Project', props.projectName);
        cdk.Tags.of(this.instance).add('Environment', props.environment);
        cdk.Tags.of(this.instance).add('ManagedBy', 'CDK');

        // 自動停止スケジュール用タグ（AWS Instance Schedulerと連携可能）
        cdk.Tags.of(this.instance).add('Schedule', 'office-hours');

        // Elastic IP（有効な場合のみ）
        if (props.enableElasticIp) {
            const eip = new ec2.CfnEIP(this, 'ElasticIp', {
                domain: 'vpc',
                tags: [
                    { key: 'Name', value: `${resourcePrefix}-eip` },
                    { key: 'Owner', value: props.username },
                    { key: 'Project', value: props.projectName },
                    { key: 'Environment', value: props.environment },
                    { key: 'ManagedBy', value: 'CDK' },
                ],
            });

            new ec2.CfnEIPAssociation(this, 'ElasticIpAssociation', {
                allocationId: eip.attrAllocationId,
                instanceId: this.instance.instanceId,
            });

            this.elasticIp = eip;
        }
    }
}
