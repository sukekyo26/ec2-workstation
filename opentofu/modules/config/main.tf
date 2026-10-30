# リポジトリルートの workstation-config.json を読み込み、各ルート (stacks/*) に渡す。
# 設定の仕様（必須項目・型・値域）は workstation-config.schema.json が唯一の定義で、
# `scripts/validate-config.sh`（CI・just・deploy の前）が強制する。ここでは検証・デフォルト適用を行わず、
# per-user override のマージと、ルートの間で共有する名前の組み立てのみ行う。
locals {
  raw_config = jsondecode(file("${path.module}/../../../workstation-config.json"))

  resource_prefix = "${local.raw_config.projectName}-${local.raw_config.environment}"
}

# デプロイ先のリージョン。両方のルートの provider と scripts/lib/tofu-common.sh (残った VPC の検査) がここから取る
output "aws_region" {
  description = "AWS region to deploy into"
  value       = local.raw_config.awsRegion
}

# network のリソースの名前の頭。VPC とサブネットの Name タグもこれから作る
output "resource_prefix" {
  description = "Prefix of the shared network resource names (<projectName>-<environment>)"
  value       = local.resource_prefix
}

# モジュールが作る IAM のロールの permissions boundary の名前 (cloudformation/permissions-boundary.yaml が作る)。
# 同じ名前を cloudformation/codepipeline.yaml の条件も使う (opentofu/stacks/workstations/tests/boundary.tftest.hcl がそろうことを見る)
output "permissions_boundary_name" {
  description = "Name of the permissions boundary policy of the module roles"
  value       = "${local.resource_prefix}-permissions-boundary"
}

output "project_name" {
  description = "Project name used for resource naming"
  value       = local.raw_config.projectName
}

output "environment" {
  description = "Environment name (dev, staging, prod)"
  value       = local.raw_config.environment
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = local.raw_config.vpcCidr
}

# network のルートが付ける Name タグ。workstations のルートと scripts/tofu-deploy.sh は、この名前で VPC とサブネットを引く
output "vpc_name" {
  description = "Name tag of the shared VPC"
  value       = "${local.resource_prefix}-vpc"
}

output "public_subnet_name" {
  description = "Name tag of the shared public subnet"
  value       = "${local.resource_prefix}-public-subnet"
}

output "default_tags" {
  description = "Tags every resource gets through the provider's default_tags"
  value = {
    Project     = local.raw_config.projectName
    Environment = local.raw_config.environment
    ManagedBy   = "OpenTofu"
  }
}

output "auto_stop_config" {
  description = "autoStopConfig in workstation-config.json"
  value       = local.raw_config.autoStopConfig
}

# ユーザー名をキーにする (stacks/workstations は、workspace の名前のユーザーだけを持つ)。
# try() はオプションキー (instanceConfig / enableElasticIp) の欠落時アクセス用。
output "users" {
  description = "Per-user settings keyed by username, with defaultInstanceConfig merged in"
  value = {
    for user in local.raw_config.users : user.username => {
      instance_config   = merge(local.raw_config.defaultInstanceConfig, try(user.instanceConfig, {}))
      enable_elastic_ip = try(user.enableElasticIp, local.raw_config.enableElasticIp)
    }
  }
}
