module "network" {
  source = "./modules/network"

  project_name = local.project_name
  environment  = local.environment
  vpc_cidr     = local.vpc_cidr
}

module "workspace" {
  source   = "./modules/workspace"
  for_each = local.users

  project_name = local.project_name
  environment  = local.environment
  username     = each.key

  vpc_id    = module.network.vpc_id
  subnet_id = module.network.public_subnet_id

  instance_type = each.value.instance_config.instanceType
  volume_size   = each.value.instance_config.volumeSize
  volume_type   = each.value.instance_config.volumeType

  user_data         = file("${path.module}/../shared/user-data.sh")
  enable_elastic_ip = each.value.enable_elastic_ip

  cpu_threshold = local.auto_stop_config.cpuThreshold
  # CloudWatch Alarm は 5 分周期のため、監視期間(分)を期間数に変換 (CDK と同じ)
  cpu_evaluation_periods = ceil(local.auto_stop_config.cpuEvaluationMinutes / 5)
  scheduled_stop_hour    = local.auto_stop_config.scheduledStopHour
  scheduled_stop_minute  = local.auto_stop_config.scheduledStopMinute
}
