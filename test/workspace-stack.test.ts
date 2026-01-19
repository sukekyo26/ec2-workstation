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

        test('デフォルトでt3.largeインスタンスが使用される', () => {
            template.hasResourceProperties('AWS::EC2::Instance', {
                InstanceType: 't3.large',
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

        test('デフォルトで100GBのボリュームサイズ', () => {
            template.hasResourceProperties('AWS::EC2::Instance', {
                BlockDeviceMappings: Match.arrayWith([
                    Match.objectLike({
                        DeviceName: '/dev/sda1',
                        Ebs: Match.objectLike({
                            VolumeSize: 100,
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
            template.resourceCountIs('AWS::IAM::Role', 1);
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
});
