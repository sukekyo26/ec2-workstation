import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as fs from 'fs';
import * as path from 'path';
import { Construct } from 'constructs';
import { SecurityConstruct } from '../constructs/security-construct';
import { Ec2Construct } from '../constructs/ec2-construct';
import { AutoStopConstruct } from '../constructs/auto-stop-construct';
import {
    WorkstationUserConfig,
    InstanceConfig,
    AutoStopConfig,
    getInstanceConfig,
    resolveElasticIp,
} from '../config/workstation-config';

/**
 * Workstation Stackのプロパティ
 */
export interface WorkstationStackProps extends cdk.StackProps {
    /** VPC（NetworkStackから渡される） */
    readonly vpc: ec2.IVpc;
    /** プロジェクト名 */
    readonly projectName: string;
    /** 環境名 */
    readonly environment: string;
    /** ユーザー設定 */
    readonly userConfig: WorkstationUserConfig;
    /** デフォルトインスタンス設定 */
    readonly defaultInstanceConfig: InstanceConfig;
    /** 自動停止設定 */
    readonly autoStopConfig: AutoStopConfig;
    /** Elastic IP のプロジェクトデフォルト */
    readonly enableElasticIp: boolean;
}

/**
 * Workstation Stack
 * 個人用のEC2ワークステーションを作成
 * - セキュリティグループ
 * - IAMロール・インスタンスプロファイル
 * - EC2インスタンス
 * - CloudWatch Logsグループ（セッションログ用）
 */
export class WorkstationStack extends cdk.Stack {
    /** EC2インスタンスID */
    public readonly instanceId: string;
    /** セッションログのロググループ名 */
    public readonly sessionLogGroupName: string;

    constructor(scope: Construct, id: string, props: WorkstationStackProps) {
        super(scope, id, props);

        const { vpc, projectName, environment, userConfig } = props;
        const instanceConfig = getInstanceConfig(userConfig, props.defaultInstanceConfig);
        const autoStopConfig = props.autoStopConfig;
        const enableElasticIp = resolveElasticIp(userConfig, props.enableElasticIp);

        // Security Construct
        const security = new SecurityConstruct(this, 'Security', {
            vpc,
            projectName,
            environment,
            username: userConfig.username,
        });

        // User Dataスクリプトを読み込む
        const userDataScript = fs.readFileSync(
            path.join(__dirname, '../../../shared/user-data.sh'),
            'utf8'
        );

        // User Data作成
        const userData = ec2.UserData.forLinux();
        userData.addCommands(userDataScript);

        // EC2 Construct
        const ec2Instance = new Ec2Construct(this, 'Ec2', {
            vpc,
            securityGroup: security.securityGroup,
            instanceProfile: security.instanceProfile,
            projectName,
            environment,
            username: userConfig.username,
            instanceConfig,
            userData,
            enableElasticIp,
        });

        this.instanceId = ec2Instance.instanceId;
        this.sessionLogGroupName = security.sessionLogGroup.logGroupName;

        // Auto Stop Construct（自動停止機能）
        const autoStop = new AutoStopConstruct(this, 'AutoStop', {
            instance: ec2Instance.instance,
            projectName,
            environment,
            username: userConfig.username,
            cpuThreshold: autoStopConfig.cpuThreshold,
            cpuEvaluationPeriods: Math.ceil(autoStopConfig.cpuEvaluationMinutes / 5), // 5分単位に変換
            scheduledStopHour: autoStopConfig.scheduledStopHour,
            scheduledStopMinute: autoStopConfig.scheduledStopMinute,
        });

        // Outputs
        new cdk.CfnOutput(this, 'InstanceId', {
            value: this.instanceId,
            description: `EC2 Instance ID for ${userConfig.username}`,
            exportName: `${projectName}-${environment}-${userConfig.username}-instance-id`,
        });

        new cdk.CfnOutput(this, 'SessionLogGroup', {
            value: this.sessionLogGroupName,
            description: `Session log group for ${userConfig.username}`,
        });

        new cdk.CfnOutput(this, 'ConnectCommand', {
            value: `aws ssm start-session --target ${this.instanceId}`,
            description: 'Command to connect via SSM',
        });

        new cdk.CfnOutput(this, 'Owner', {
            value: userConfig.username,
            description: 'Workstation owner',
        });

        // Elastic IP Outputs（有効な場合のみ）
        if (ec2Instance.elasticIp) {
            new cdk.CfnOutput(this, 'ElasticIpAddress', {
                value: ec2Instance.elasticIp.attrPublicIp,
                description: `Elastic IP address for ${userConfig.username}`,
                exportName: `${projectName}-${environment}-${userConfig.username}-elastic-ip`,
            });

            new cdk.CfnOutput(this, 'ElasticIpAllocationId', {
                value: ec2Instance.elasticIp.attrAllocationId,
                description: `Elastic IP allocation ID for ${userConfig.username}`,
            });
        }
    }
}
