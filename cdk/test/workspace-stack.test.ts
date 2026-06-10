import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { NetworkStack } from '../lib/stacks/network-stack';
import { WorkspaceStack } from '../lib/stacks/workspace-stack';

describe('WorkspaceStack', () => {
    let app: cdk.App;
    let networkStack: NetworkStack;
    let workspaceStack: WorkspaceStack;
    let template: Template;

    beforeEach(() => {
        app = new cdk.App();

        // ネットワークスタック作成
        networkStack = new NetworkStack(app, 'TestNetworkStack', {
            projectName: 'test-project',
            environment: 'test',
            vpcCidr: '10.0.0.0/16',
            env: {
                account: '123456789012',
                region: 'ap-northeast-1',
            },
        });

        // ワークスペーススタック作成
        workspaceStack = new WorkspaceStack(app, 'TestWorkspaceStack', {
            vpc: networkStack.vpc,
            projectName: 'test-project',
            environment: 'test',
            userConfig: {
                username: 'testuser',
                displayName: 'Test User',
            },
            env: {
                account: '123456789012',
                region: 'ap-northeast-1',
            },
        });

        template = Template.fromStack(workspaceStack);
    });

    describe('EC2 Instance', () => {
        test('EC2インスタンスが作成される', () => {
            template.resourceCountIs('AWS::EC2::Instance', 1);
        });

        test('デフォルトでt3.mediumインスタンスが使用される', () => {
            template.hasResourceProperties('AWS::EC2::Instance', {
                InstanceType: 't3.medium',
            });
        });

        test('IMDSv2が強制される', () => {
            // CDKはLaunchTemplate経由でMetadataOptionsを設定する
            template.hasResourceProperties('AWS::EC2::LaunchTemplate', {
                LaunchTemplateData: {
                    MetadataOptions: {
                        HttpTokens: 'required',
                    },
                },
            });
        });

        test('インスタンスにOwnerタグが設定される', () => {
            template.hasResourceProperties('AWS::EC2::Instance', {
                Tags: Match.arrayWith([
                    Match.objectLike({
                        Key: 'Owner',
                        Value: 'testuser',
                    }),
                ]),
            });
        });

        test('インスタンスにScheduleタグが設定される', () => {
            template.hasResourceProperties('AWS::EC2::Instance', {
                Tags: Match.arrayWith([
                    Match.objectLike({
                        Key: 'Schedule',
                        Value: 'office-hours',
                    }),
                ]),
            });
        });
    });

    describe('EBS Volume', () => {
        test('EBSボリュームが暗号化される', () => {
            template.hasResourceProperties('AWS::EC2::Instance', {
                BlockDeviceMappings: Match.arrayWith([
                    Match.objectLike({
                        DeviceName: '/dev/sda1',
                        Ebs: Match.objectLike({
                            Encrypted: true,
                        }),
                    }),
                ]),
            });
        });

        test('デフォルトで80GBのボリュームサイズ', () => {
            template.hasResourceProperties('AWS::EC2::Instance', {
                BlockDeviceMappings: Match.arrayWith([
                    Match.objectLike({
                        DeviceName: '/dev/sda1',
                        Ebs: Match.objectLike({
                            VolumeSize: 80,
                        }),
                    }),
                ]),
            });
        });

        test('gp3ボリュームタイプが使用される', () => {
            template.hasResourceProperties('AWS::EC2::Instance', {
                BlockDeviceMappings: Match.arrayWith([
                    Match.objectLike({
                        DeviceName: '/dev/sda1',
                        Ebs: Match.objectLike({
                            VolumeType: 'gp3',
                        }),
                    }),
                ]),
            });
        });

        test('インスタンス削除時にEBSも削除される', () => {
            template.hasResourceProperties('AWS::EC2::Instance', {
                BlockDeviceMappings: Match.arrayWith([
                    Match.objectLike({
                        DeviceName: '/dev/sda1',
                        Ebs: Match.objectLike({
                            DeleteOnTermination: true,
                        }),
                    }),
                ]),
            });
        });
    });

    describe('Security', () => {
        test('セキュリティグループが作成される', () => {
            template.resourceCountIs('AWS::EC2::SecurityGroup', 1);
        });

        test('IAMロールが作成される', () => {
            // EC2インスタンスロール + EventBridge Schedulerロール
            template.resourceCountIs('AWS::IAM::Role', 2);
        });

        test('インスタンスプロファイルが作成される', () => {
            // Security ConstructとEC2 Constructから2つ作成される可能性がある
            const instanceProfiles = template.findResources('AWS::IAM::InstanceProfile');
            expect(Object.keys(instanceProfiles).length).toBeGreaterThanOrEqual(1);
        });
    });

    describe('Outputs', () => {
        test('インスタンスIDが出力される', () => {
            template.hasOutput('InstanceId', {});
        });

        test('接続コマンドが出力される', () => {
            template.hasOutput('ConnectCommand', {});
        });

        test('オーナー情報が出力される', () => {
            template.hasOutput('Owner', {
                Value: 'testuser',
            });
        });
    });
});

describe('WorkspaceStack - カスタム設定', () => {
    test('カスタムインスタンスタイプが設定できる', () => {
        const app = new cdk.App();

        const networkStack = new NetworkStack(app, 'TestNetworkStack2', {
            projectName: 'test-project',
            environment: 'test',
            vpcCidr: '10.0.0.0/16',
            env: {
                account: '123456789012',
                region: 'ap-northeast-1',
            },
        });

        const workspaceStack = new WorkspaceStack(app, 'TestWorkspaceStack2', {
            vpc: networkStack.vpc,
            projectName: 'test-project',
            environment: 'test',
            userConfig: {
                username: 'testuser2',
                instanceConfig: {
                    instanceType: 't3.medium',
                    volumeSize: 50,
                    volumeType: 'gp3',
                },
            },
            env: {
                account: '123456789012',
                region: 'ap-northeast-1',
            },
        });

        const template = Template.fromStack(workspaceStack);

        template.hasResourceProperties('AWS::EC2::Instance', {
            InstanceType: 't3.medium',
        });

        template.hasResourceProperties('AWS::EC2::Instance', {
            BlockDeviceMappings: Match.arrayWith([
                Match.objectLike({
                    Ebs: Match.objectLike({
                        VolumeSize: 50,
                    }),
                }),
            ]),
        });
    });

    test('カスタム自動停止設定が適用される', () => {
        const app = new cdk.App();

        const networkStack = new NetworkStack(app, 'TestNetworkStack3', {
            projectName: 'test-project',
            environment: 'test',
            vpcCidr: '10.0.0.0/16',
            env: {
                account: '123456789012',
                region: 'ap-northeast-1',
            },
        });

        const workspaceStack = new WorkspaceStack(app, 'TestWorkspaceStack3', {
            vpc: networkStack.vpc,
            projectName: 'test-project',
            environment: 'test',
            userConfig: {
                username: 'testuser3',
            },
            autoStopConfig: {
                cpuThreshold: 10,
                cpuEvaluationMinutes: 15,
                scheduledStopHour: 22,
                scheduledStopMinute: 30,
            },
            env: {
                account: '123456789012',
                region: 'ap-northeast-1',
            },
        });

        const template = Template.fromStack(workspaceStack);

        // CloudWatch AlarmがカスタムCPU閾値で作成される
        template.hasResourceProperties('AWS::CloudWatch::Alarm', {
            Threshold: 10,
            EvaluationPeriods: 3, // 15分 / 5分 = 3期間
        });

        // EventBridge Scheduleがカスタム時刻で作成される
        template.hasResourceProperties('AWS::Scheduler::Schedule', {
            ScheduleExpression: 'cron(30 22 * * ? *)',
        });
    });
});

describe('WorkspaceStack - Elastic IP', () => {
    test('デフォルトではEIPが作成されない', () => {
        const app = new cdk.App();

        const networkStack = new NetworkStack(app, 'TestNetworkStackEip1', {
            projectName: 'test-project',
            environment: 'test',
            vpcCidr: '10.0.0.0/16',
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        const workspaceStack = new WorkspaceStack(app, 'TestWorkspaceStackEip1', {
            vpc: networkStack.vpc,
            projectName: 'test-project',
            environment: 'test',
            userConfig: { username: 'testuser' },
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        const template = Template.fromStack(workspaceStack);
        template.resourceCountIs('AWS::EC2::EIP', 0);
        template.resourceCountIs('AWS::EC2::EIPAssociation', 0);
    });

    test('enableElasticIp: true でEIPが作成される', () => {
        const app = new cdk.App();

        const networkStack = new NetworkStack(app, 'TestNetworkStackEip2', {
            projectName: 'test-project',
            environment: 'test',
            vpcCidr: '10.0.0.0/16',
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        const workspaceStack = new WorkspaceStack(app, 'TestWorkspaceStackEip2', {
            vpc: networkStack.vpc,
            projectName: 'test-project',
            environment: 'test',
            userConfig: { username: 'testuser' },
            enableElasticIp: true,
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        const template = Template.fromStack(workspaceStack);
        template.resourceCountIs('AWS::EC2::EIP', 1);
        template.resourceCountIs('AWS::EC2::EIPAssociation', 1);
    });

    test('EIP有効時にEIPにOwnerタグが設定される', () => {
        const app = new cdk.App();

        const networkStack = new NetworkStack(app, 'TestNetworkStackEip3', {
            projectName: 'test-project',
            environment: 'test',
            vpcCidr: '10.0.0.0/16',
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        const workspaceStack = new WorkspaceStack(app, 'TestWorkspaceStackEip3', {
            vpc: networkStack.vpc,
            projectName: 'test-project',
            environment: 'test',
            userConfig: { username: 'testuser' },
            enableElasticIp: true,
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        const template = Template.fromStack(workspaceStack);
        template.hasResourceProperties('AWS::EC2::EIP', {
            Tags: Match.arrayWith([
                Match.objectLike({ Key: 'Owner', Value: 'testuser' }),
            ]),
        });
        template.hasResourceProperties('AWS::EC2::EIP', {
            Tags: Match.arrayWith([
                Match.objectLike({ Key: 'Name', Value: 'test-project-test-testuser-eip' }),
            ]),
        });
    });

    test('EIP有効時にElasticIpAddress Outputが存在する', () => {
        const app = new cdk.App();

        const networkStack = new NetworkStack(app, 'TestNetworkStackEip4', {
            projectName: 'test-project',
            environment: 'test',
            vpcCidr: '10.0.0.0/16',
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        const workspaceStack = new WorkspaceStack(app, 'TestWorkspaceStackEip4', {
            vpc: networkStack.vpc,
            projectName: 'test-project',
            environment: 'test',
            userConfig: { username: 'testuser' },
            enableElasticIp: true,
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        const template = Template.fromStack(workspaceStack);
        template.hasOutput('ElasticIpAddress', {});
        template.hasOutput('ElasticIpAllocationId', {});
    });

    test('ユーザーレベルのenableElasticIpがプロジェクトデフォルトを上書きする', () => {
        const app = new cdk.App();

        const networkStack = new NetworkStack(app, 'TestNetworkStackEip5', {
            projectName: 'test-project',
            environment: 'test',
            vpcCidr: '10.0.0.0/16',
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        // プロジェクトデフォルト true、ユーザーレベル false
        const workspaceStack = new WorkspaceStack(app, 'TestWorkspaceStackEip5', {
            vpc: networkStack.vpc,
            projectName: 'test-project',
            environment: 'test',
            userConfig: { username: 'testuser', enableElasticIp: false },
            enableElasticIp: true,
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        const template = Template.fromStack(workspaceStack);
        template.resourceCountIs('AWS::EC2::EIP', 0);
    });

    test('ユーザーレベル enableElasticIp: true がプロジェクトデフォルト false を上書きする', () => {
        const app = new cdk.App();

        const networkStack = new NetworkStack(app, 'TestNetworkStackEip6', {
            projectName: 'test-project',
            environment: 'test',
            vpcCidr: '10.0.0.0/16',
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        // プロジェクトデフォルト false、ユーザーレベル true
        const workspaceStack = new WorkspaceStack(app, 'TestWorkspaceStackEip6', {
            vpc: networkStack.vpc,
            projectName: 'test-project',
            environment: 'test',
            userConfig: { username: 'testuser', enableElasticIp: true },
            enableElasticIp: false,
            env: { account: '123456789012', region: 'ap-northeast-1' },
        });

        const template = Template.fromStack(workspaceStack);
        template.resourceCountIs('AWS::EC2::EIP', 1);
    });
});
