#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { NetworkStack } from '../lib/stacks/network-stack';
import { WorkstationStack } from '../lib/stacks/workstation-stack';
import { loadProjectConfig } from '../lib/config/workstation-config';

const app = new cdk.App();

// ============================================================
// 設定ファイルからプロジェクト設定を読み込み
// ============================================================
// workstation-config.json でユーザーとプロジェクト設定を定義
// ============================================================
const projectConfig = loadProjectConfig();
const { projectName, environment, vpcCidr, users, defaultInstanceConfig, autoStopConfig, enableElasticIp } = projectConfig;

// AWS環境設定
const env: cdk.Environment = {
  account: process.env.CDK_DEFAULT_ACCOUNT || process.env.AWS_ACCOUNT_ID,
  region: process.env.CDK_DEFAULT_REGION || process.env.AWS_REGION || 'ap-northeast-1',
};

// ============================================================
// 共有ネットワークスタック
// ============================================================
const networkStack = new NetworkStack(app, `${projectName}-${environment}-network`, {
  env,
  projectName,
  environment,
  vpcCidr,
  description: `Network stack for ${projectName} (${environment}) - VPC, Subnet, IGW, Flow Logs`,
  tags: {
    Project: projectName,
    Environment: environment,
    ManagedBy: 'CDK',
  },
});

// ============================================================
// 個人用ワークステーションスタック
// workstation-config.json の users で定義されたユーザー分を作成
// ============================================================
for (const userConfig of users) {
  const workstationStack = new WorkstationStack(
    app,
    `${projectName}-${environment}-${userConfig.username}`,
    {
      env,
      vpc: networkStack.vpc,
      projectName,
      environment,
      userConfig,
      defaultInstanceConfig,
      autoStopConfig,
      enableElasticIp,
      description: `Workstation for ${userConfig.username} (${environment})`,
      tags: {
        Project: projectName,
        Environment: environment,
        Owner: userConfig.username,
        ManagedBy: 'CDK',
      },
    }
  );

  workstationStack.addDependency(networkStack);
}

app.synth();
