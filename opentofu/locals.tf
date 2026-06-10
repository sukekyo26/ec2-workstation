# workspace-config.json (リポジトリルート、CDK 実装と共有) を読み込む。
# 設定の仕様（必須項目・型・値域）は workspace-config.schema.json が唯一の定義で、
# CDK 実行時 (ajv) と CI (ajv-cli) が強制する。ここでは検証・デフォルト適用を行わず、
# per-user override のマージのみ行う。
locals {
  raw_config = jsondecode(file("${path.module}/../workspace-config.json"))

  project_name = local.raw_config.projectName
  environment  = local.raw_config.environment
  vpc_cidr     = local.raw_config.vpcCidr

  default_instance_config = local.raw_config.defaultInstanceConfig
  auto_stop_config        = local.raw_config.autoStopConfig

  # ユーザー名をキーにすることで、ユーザーの追加・削除が他ユーザーの
  # リソースに影響しない (CDK のスタック分割と同等の独立性)。
  # try() はオプションキー (instanceConfig / enableElasticIp) の欠落時アクセス用。
  users = {
    for user in local.raw_config.users : user.username => {
      instance_config   = merge(local.default_instance_config, try(user.instanceConfig, {}))
      enable_elastic_ip = try(user.enableElasticIp, local.raw_config.enableElasticIp)
    }
  }
}
