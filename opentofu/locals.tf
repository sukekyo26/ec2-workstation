# workspace-config.json (リポジトリルート、CDK 実装と共有) を直接読み込み、
# cdk/lib/config/workspace-config.ts の validateAndParseConfig / getInstanceConfig /
# resolveElasticIp と同じデフォルト適用・マージを再現する。
locals {
  raw_config = jsondecode(file("${path.module}/../workspace-config.json"))

  project_name = try(local.raw_config.projectName, "ec2-remote-workspace")
  environment  = try(local.raw_config.environment, "dev")
  vpc_cidr     = try(local.raw_config.vpcCidr, "10.0.0.0/16")

  default_instance_config = merge(
    {
      instanceType = "t3.medium"
      volumeSize   = 80
      volumeType   = "gp3"
    },
    try(local.raw_config.defaultInstanceConfig, {})
  )

  auto_stop_config = merge(
    {
      cpuThreshold         = 5
      cpuEvaluationMinutes = 10
      scheduledStopHour    = 23
      scheduledStopMinute  = 0
    },
    try(local.raw_config.autoStopConfig, {})
  )

  enable_elastic_ip_default = try(local.raw_config.enableElasticIp, false)

  # ユーザー名をキーにすることで、ユーザーの追加・削除が他ユーザーの
  # リソースに影響しない (CDK のスタック分割と同等の独立性)
  users = {
    for user in local.raw_config.users : user.username => {
      instance_config   = merge(local.default_instance_config, try(user.instanceConfig, {}))
      enable_elastic_ip = try(user.enableElasticIp, local.enable_elastic_ip_default)
    }
  }
}
