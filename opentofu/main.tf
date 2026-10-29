module "network" {
  source = "./modules/network"

  project_name = local.project_name
  environment  = local.environment
  vpc_cidr     = local.vpc_cidr
}

module "workstation" {
  source   = "./modules/workstation"
  for_each = local.users

  project_name = local.project_name
  environment  = local.environment
  username     = each.key

  vpc_id            = module.network.vpc_id
  subnet_id         = module.network.public_subnet_id
  availability_zone = module.network.public_subnet_availability_zone

  instance_type    = each.value.instance_config.instanceType
  root_volume_size = each.value.instance_config.rootVolumeSize
  root_volume_type = each.value.instance_config.rootVolumeType
  data_volume_size = each.value.instance_config.dataVolumeSize
  data_volume_type = each.value.instance_config.dataVolumeType

  user_data_template = "${path.module}/../shared/user-data.sh"
  enable_elastic_ip  = each.value.enable_elastic_ip

  cpu_threshold = local.auto_stop_config.cpuThreshold
  # CloudWatch Alarm は 5 分周期のため、監視期間(分)を期間数に変換
  cpu_evaluation_periods = ceil(local.auto_stop_config.cpuEvaluationMinutes / 5)
  scheduled_stop_hour    = local.auto_stop_config.scheduledStopHour
  scheduled_stop_minute  = local.auto_stop_config.scheduledStopMinute
}
