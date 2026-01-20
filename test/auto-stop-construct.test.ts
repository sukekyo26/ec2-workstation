import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { AutoStopConstruct } from '../lib/constructs/auto-stop-construct';

describe('AutoStopConstruct', () => {
    let app: cdk.App;
    let stack: cdk.Stack;
    let vpc: ec2.Vpc;
    let instance: ec2.Instance;
    let template: Template;

    beforeEach(() => {
        app = new cdk.App();
        stack = new cdk.Stack(app, 'TestStack', {
            env: {
                account: '123456789012',
                region: 'ap-northeast-1',
            },
        });

        // テスト用VPCを作成
        vpc = new ec2.Vpc(stack, 'TestVpc', {
            maxAzs: 1,
            natGateways: 0,
        });

        // テスト用EC2インスタンスを作成
        instance = new ec2.Instance(stack, 'TestInstance', {
            vpc,
            instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MEDIUM),
            machineImage: ec2.MachineImage.latestAmazonLinux2023(),
        });

        // AutoStopConstructを作成
        new AutoStopConstruct(stack, 'TestAutoStop', {
            instance,
            projectName: 'test-project',
            environment: 'test',
            username: 'testuser',
            cpuThreshold: 5,
            cpuEvaluationPeriods: 2,
            scheduledStopHour: 23,
            scheduledStopMinute: 0,
        });

        template = Template.fromStack(stack);
    });

    describe('CloudWatch Alarm', () => {
        test('CloudWatch Alarmが作成される', () => {
            template.resourceCountIs('AWS::CloudWatch::Alarm', 1);
        });

        test('Alarmに正しい名前が設定される', () => {
            template.hasResourceProperties('AWS::CloudWatch::Alarm', {
                AlarmName: 'test-project-test-testuser-cpu-low-alarm',
            });
        });

        test('CPU使用率5%以下で発火する設定', () => {
            template.hasResourceProperties('AWS::CloudWatch::Alarm', {
                Threshold: 5,
                ComparisonOperator: 'LessThanThreshold',
            });
        });

        test('2評価期間で発火する設定', () => {
            template.hasResourceProperties('AWS::CloudWatch::Alarm', {
                EvaluationPeriods: 2,
            });
        });

        test('EC2停止アクションが設定される', () => {
            // AlarmActionsが設定されていることを確認
            template.hasResourceProperties('AWS::CloudWatch::Alarm', {
                AlarmActions: Match.anyValue(),
            });

            // Alarmリソースを取得して詳細を確認
            const alarms = template.findResources('AWS::CloudWatch::Alarm');
            const alarmKeys = Object.keys(alarms);
            expect(alarmKeys.length).toBe(1);

            const alarm = alarms[alarmKeys[0]];
            const alarmActions = alarm.Properties.AlarmActions;
            expect(alarmActions).toBeDefined();
            expect(alarmActions.length).toBeGreaterThan(0);

            // ec2:stopアクションが含まれていることを確認
            const actionStr = JSON.stringify(alarmActions);
            expect(actionStr).toContain('ec2:stop');
        });

        test('CPUUtilizationメトリクスを使用', () => {
            template.hasResourceProperties('AWS::CloudWatch::Alarm', {
                MetricName: 'CPUUtilization',
                Namespace: 'AWS/EC2',
            });
        });
    });

    describe('EventBridge Scheduler', () => {
        test('EventBridge Scheduleが作成される', () => {
            template.resourceCountIs('AWS::Scheduler::Schedule', 1);
        });

        test('Scheduleに正しい名前が設定される', () => {
            template.hasResourceProperties('AWS::Scheduler::Schedule', {
                Name: 'test-project-test-testuser-daily-stop',
            });
        });

        test('cron式が正しく設定される', () => {
            template.hasResourceProperties('AWS::Scheduler::Schedule', {
                ScheduleExpression: 'cron(0 23 * * ? *)',
            });
        });

        test('タイムゾーンがAsia/Tokyoに設定される', () => {
            template.hasResourceProperties('AWS::Scheduler::Schedule', {
                ScheduleExpressionTimezone: 'Asia/Tokyo',
            });
        });

        test('EC2 stopInstancesターゲットが設定される', () => {
            template.hasResourceProperties('AWS::Scheduler::Schedule', {
                Target: Match.objectLike({
                    Arn: 'arn:aws:scheduler:::aws-sdk:ec2:stopInstances',
                }),
            });
        });

        test('スケジュールが有効状態', () => {
            template.hasResourceProperties('AWS::Scheduler::Schedule', {
                State: 'ENABLED',
            });
        });
    });

    describe('IAM Role for Scheduler', () => {
        test('Scheduler用IAMロールが作成される', () => {
            // EC2インスタンスのロールとSchedulerのロールで2つ
            template.resourceCountIs('AWS::IAM::Role', 2);
        });

        test('SchedulerサービスがAssumeRoleできる', () => {
            template.hasResourceProperties('AWS::IAM::Role', {
                AssumeRolePolicyDocument: {
                    Statement: Match.arrayWith([
                        Match.objectLike({
                            Action: 'sts:AssumeRole',
                            Effect: 'Allow',
                            Principal: {
                                Service: 'scheduler.amazonaws.com',
                            },
                        }),
                    ]),
                },
            });
        });

        test('EC2停止権限が付与される', () => {
            template.hasResourceProperties('AWS::IAM::Policy', {
                PolicyDocument: {
                    Statement: Match.arrayWith([
                        Match.objectLike({
                            Action: 'ec2:StopInstances',
                            Effect: 'Allow',
                        }),
                    ]),
                },
            });
        });
    });

    describe('Default values', () => {
        test('デフォルト値でConstructが作成できる', () => {
            const defaultApp = new cdk.App();
            const defaultStack = new cdk.Stack(defaultApp, 'DefaultStack', {
                env: {
                    account: '123456789012',
                    region: 'ap-northeast-1',
                },
            });

            const defaultVpc = new ec2.Vpc(defaultStack, 'DefaultVpc', {
                maxAzs: 1,
                natGateways: 0,
            });

            const defaultInstance = new ec2.Instance(defaultStack, 'DefaultInstance', {
                vpc: defaultVpc,
                instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3, ec2.InstanceSize.MEDIUM),
                machineImage: ec2.MachineImage.latestAmazonLinux2023(),
            });

            // デフォルト値でConstruct作成（エラーが出ないことを確認）
            new AutoStopConstruct(defaultStack, 'DefaultAutoStop', {
                instance: defaultInstance,
                projectName: 'default-project',
                environment: 'dev',
                username: 'defaultuser',
            });

            const defaultTemplate = Template.fromStack(defaultStack);
            defaultTemplate.resourceCountIs('AWS::CloudWatch::Alarm', 1);
            defaultTemplate.resourceCountIs('AWS::Scheduler::Schedule', 1);
        });
    });
});
