# workspace-config.json (リポジトリルート、CDK 実装と共有) を直接読み込み、
# cdk/lib/config/workspace-config.ts の validateAndParseConfig / getInstanceConfig /
# resolveElasticIp と同じデフォルト適用・マージを再現する。
#
# null 耐性: キー欠落だけでなく明示的な null もデフォルトへフォールバックさせる
# (CDK の typeof チェック / ?? と同等)。
# - try(coalesce(x, default), default): x が欠落・null なら default
# - try(merge(x), {}):                  x が欠落・null・非オブジェクトなら {}
#   (tomap() は instanceType/volumeSize のような混在型オブジェクトを変換できないため使わない)
locals {
  raw_config = jsondecode(file("${path.module}/../workspace-config.json"))

  project_name = try(coalesce(local.raw_config.projectName, "ec2-remote-workspace"), "ec2-remote-workspace")
  environment  = try(coalesce(local.raw_config.environment, "dev"), "dev")
  vpc_cidr     = try(coalesce(local.raw_config.vpcCidr, "10.0.0.0/16"), "10.0.0.0/16")

  default_instance_config = merge(
    {
      instanceType = "t3.medium"
      volumeSize   = 80
      volumeType   = "gp3"
    },
    try(merge(local.raw_config.defaultInstanceConfig), {})
  )

  auto_stop_config = merge(
    {
      cpuThreshold         = 5
      cpuEvaluationMinutes = 10
      scheduledStopHour    = 23
      scheduledStopMinute  = 0
    },
    try(merge(local.raw_config.autoStopConfig), {})
  )

  enable_elastic_ip_default = try(tobool(coalesce(local.raw_config.enableElasticIp, false)), false)

  # ユーザー名をキーにすることで、ユーザーの追加・削除が他ユーザーの
  # リソースに影響しない (CDK のスタック分割と同等の独立性)
  users = {
    for user in local.raw_config.users : user.username => {
      instance_config   = merge(local.default_instance_config, try(merge(user.instanceConfig), {}))
      enable_elastic_ip = try(tobool(coalesce(user.enableElasticIp, local.enable_elastic_ip_default)), local.enable_elastic_ip_default)
    }
  }
}
