import * as cdk from 'aws-cdk-lib';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { NetworkStack } from '../lib/stacks/network-stack';

describe('NetworkStack', () => {
    let app: cdk.App;
    let stack: NetworkStack;
    let template: Template;

    beforeEach(() => {
        app = new cdk.App();
        stack = new NetworkStack(app, 'TestNetworkStack', {
            projectName: 'test-project',
            environment: 'test',
            vpcCidr: '10.0.0.0/16',
            env: {
                account: '123456789012',
                region: 'ap-northeast-1',
            },
        });
        template = Template.fromStack(stack);
    });

    describe('VPC', () => {
        test('VPCが作成される', () => {
            template.resourceCountIs('AWS::EC2::VPC', 1);
        });

        test('VPCに正しいCIDRが設定される', () => {
            template.hasResourceProperties('AWS::EC2::VPC', {
                CidrBlock: '10.0.0.0/16',
            });
        });

        test('DNS設定が有効化される', () => {
            template.hasResourceProperties('AWS::EC2::VPC', {
                EnableDnsHostnames: true,
                EnableDnsSupport: true,
            });
        });
    });

    describe('Subnet', () => {
        test('Public Subnetが作成される', () => {
            template.resourceCountIs('AWS::EC2::Subnet', 1);
        });

        test('SubnetがパブリックIPを自動割り当て', () => {
            template.hasResourceProperties('AWS::EC2::Subnet', {
                MapPublicIpOnLaunch: true,
            });
        });
    });

    describe('Internet Gateway', () => {
        test('Internet Gatewayが作成される', () => {
            template.resourceCountIs('AWS::EC2::InternetGateway', 1);
        });

        test('Internet GatewayがVPCにアタッチされる', () => {
            template.resourceCountIs('AWS::EC2::VPCGatewayAttachment', 1);
        });
    });

    describe('Route Table', () => {
        test('Route Tableが作成される', () => {
            template.resourceCountIs('AWS::EC2::RouteTable', 1);
        });

        test('デフォルトルートがInternet Gatewayを向く', () => {
            template.hasResourceProperties('AWS::EC2::Route', {
                DestinationCidrBlock: '0.0.0.0/0',
            });
        });
    });

    describe('NAT Gateway', () => {
        test('NAT Gatewayが作成されない（コスト削減）', () => {
            template.resourceCountIs('AWS::EC2::NatGateway', 0);
        });
    });

    describe('Outputs', () => {
        test('VPC IDがエクスポートされる', () => {
            template.hasOutput('VpcIdOutput', {
                Export: {
                    Name: 'test-project-test-vpc-id',
                },
            });
        });

        test('Public Subnet IDがエクスポートされる', () => {
            template.hasOutput('PublicSubnetIdOutput', {
                Export: {
                    Name: 'test-project-test-public-subnet-id',
                },
            });
        });
    });

    describe('Tags', () => {
        test('VPCにProjectタグが設定される', () => {
            template.hasResourceProperties('AWS::EC2::VPC', {
                Tags: Match.arrayWith([
                    Match.objectLike({
                        Key: 'Project',
                        Value: 'test-project',
                    }),
                ]),
            });
        });
    });
});
