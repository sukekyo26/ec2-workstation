import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as fs from 'fs';
import * as path from 'path';
import { Construct } from 'constructs';
import { SecurityConstruct } from '../constructs/security-construct';
import { Ec2Construct } from '../constructs/ec2-construct';
import { AutoStopConstruct } from '../constructs/auto-stop-construct';
import {
    WorkspaceUserConfig,
    InstanceConfig,
    getInstanceConfig,
    DEFAULT_INSTANCE_CONFIG,
} from '../config/workspace-config';

/**
 * Workspace Stackのプロパティ
 */
export interface WorkspaceStackProps extends cdk.StackProps {
    /** VPC（NetworkStackから渡される） */
    readonly vpc: ec2.IVpc;
    /** プロジェクト名 */
    readonly projectName: string;
    /** 環境名 */
    readonly environment: string;
    /** ユーザー設定 */
    readonly userConfig: WorkspaceUserConfig;
    /** デフォルトインスタンス設定 */
    readonly defaultInstanceConfig?: InstanceConfig;
}

/**
 * Workspace Stack
 * 個人用のEC2ワークスペースを作成
 * - セキュリティグループ
 * - IAMロール・インスタンスプロファイル
 * - EC2インスタンス
 * - CloudWatch Logsグループ（セッションログ用）
 */
export class WorkspaceStack extends cdk.Stack {
    /** EC2インスタンスID */
    public readonly instanceId: string;
    /** セッションログのロググループ名 */
    public readonly sessionLogGroupName: string;

    constructor(scope: Construct, id: string, props: WorkspaceStackProps) {
        super(scope, id, props);

        const { vpc, projectName, environment, userConfig } = props;
        const defaultConfig = props.defaultInstanceConfig || DEFAULT_INSTANCE_CONFIG;
        const instanceConfig = getInstanceConfig(userConfig, defaultConfig);

        // Security Construct
        const security = new SecurityConstruct(this, 'Security', {
            vpc,
            projectName,
            environment,
            username: userConfig.username,
        });

        // User Dataスクリプトを読み込む
        const userDataScript = fs.readFileSync(
            path.join(__dirname, '../scripts/user-data.sh'),
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
        });

        this.instanceId = ec2Instance.instanceId;
        this.sessionLogGroupName = security.sessionLogGroup.logGroupName;

        // Auto Stop Construct（自動停止機能）
        const autoStop = new AutoStopConstruct(this, 'AutoStop', {
            instance: ec2Instance.instance,
            projectName,
            environment,
            username: userConfig.username,
            cpuThreshold: 5, // CPU使用率5%以下
            cpuEvaluationPeriods: 2, // 10分間（5分 x 2）
            scheduledStopHour: 23, // 毎日23時（JST）
            scheduledStopMinute: 0,
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
            description: 'Workspace owner',
        });
    }
}
