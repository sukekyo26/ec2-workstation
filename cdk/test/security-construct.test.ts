import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { SecurityConstruct } from '../lib/constructs/security-construct';

describe('SecurityConstruct', () => {
    let app: cdk.App;
    let stack: cdk.Stack;
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
        const vpc = new ec2.Vpc(stack, 'TestVpc', {
            maxAzs: 1,
            natGateways: 0,
        });

        // SecurityConstructを作成
        new SecurityConstruct(stack, 'TestSecurity', {
            vpc,
            projectName: 'test-project',
            environment: 'test',
            username: 'testuser',
        });

        template = Template.fromStack(stack);
    });

    describe('Security Group', () => {
        test('セキュリティグループが作成される', () => {
            template.resourceCountIs('AWS::EC2::SecurityGroup', 1);
        });

        test('セキュリティグループに正しい名前が設定される', () => {
            template.hasResourceProperties('AWS::EC2::SecurityGroup', {
                GroupName: 'test-project-test-testuser-sg',
            });
        });

        test('インバウンドルールがない（全ブロック）', () => {
            template.hasResourceProperties('AWS::EC2::SecurityGroup', {
                SecurityGroupIngress: Match.absent(),
            });
        });

        test('アウトバウンドルールが設定される', () => {
            // CDKはSecurityGroupEgressをSecurityGroup内に含める
            template.hasResourceProperties('AWS::EC2::SecurityGroup', {
                SecurityGroupEgress: Match.arrayWith([
                    Match.objectLike({
                        IpProtocol: 'tcp',
                        FromPort: 443,
                        ToPort: 443,
                        CidrIp: '0.0.0.0/0',
                    }),
                    Match.objectLike({
                        IpProtocol: 'tcp',
                        FromPort: 80,
                        ToPort: 80,
                        CidrIp: '0.0.0.0/0',
                    }),
                    Match.objectLike({
                        IpProtocol: 'udp',
                        FromPort: 53,
                        ToPort: 53,
                        CidrIp: '0.0.0.0/0',
                    }),
                ]),
            });
        });
    });

    describe('IAM Role', () => {
        test('IAMロールが作成される', () => {
            template.resourceCountIs('AWS::IAM::Role', 1);
        });

        test('EC2サービスがAssumeRoleできる', () => {
            template.hasResourceProperties('AWS::IAM::Role', {
                AssumeRolePolicyDocument: {
                    Statement: Match.arrayWith([
                        Match.objectLike({
                            Action: 'sts:AssumeRole',
                            Effect: 'Allow',
                            Principal: {
                                Service: 'ec2.amazonaws.com',
                            },
                        }),
                    ]),
                },
            });
        });

        test('AmazonSSMManagedInstanceCoreポリシーがアタッチされる', () => {
            template.hasResourceProperties('AWS::IAM::Role', {
                ManagedPolicyArns: Match.arrayWith([
                    Match.objectLike({
                        'Fn::Join': Match.arrayWith([
                            Match.arrayWith([
                                Match.stringLikeRegexp('AmazonSSMManagedInstanceCore'),
                            ]),
                        ]),
                    }),
                ]),
            });
        });
    });

    describe('Instance Profile', () => {
        test('インスタンスプロファイルが作成される', () => {
            template.resourceCountIs('AWS::IAM::InstanceProfile', 1);
        });

        test('インスタンスプロファイルに正しい名前が設定される', () => {
            template.hasResourceProperties('AWS::IAM::InstanceProfile', {
                InstanceProfileName: 'test-project-test-testuser-instance-profile',
            });
        });
    });

    describe('CloudWatch Logs', () => {
        test('ロググループが作成される', () => {
            template.resourceCountIs('AWS::Logs::LogGroup', 1);
        });

        test('ロググループに正しい名前が設定される', () => {
            template.hasResourceProperties('AWS::Logs::LogGroup', {
                LogGroupName: '/ssm/session-logs/test-project-test-testuser',
            });
        });

        test('ログ保持期間が1ヶ月に設定される', () => {
            template.hasResourceProperties('AWS::Logs::LogGroup', {
                RetentionInDays: 30,
            });
        });
    });

    describe('Tags', () => {
        test('セキュリティグループにOwnerタグが設定される', () => {
            template.hasResourceProperties('AWS::EC2::SecurityGroup', {
                Tags: Match.arrayWith([
                    Match.objectLike({
                        Key: 'Owner',
                        Value: 'testuser',
                    }),
                ]),
            });
        });
    });
});
