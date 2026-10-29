module "config" {
  source = "../../modules/config"
}

module "workstation" {
  source   = "../../modules/workstation"
  for_each = module.config.users

  project_name = module.config.project_name
  environment  = module.config.environment
  username     = each.key

  vpc_id            = data.aws_vpc.this.id
  subnet_id         = data.aws_subnet.public.id
  availability_zone = data.aws_subnet.public.availability_zone

  os               = each.value.instance_config.os
  instance_type    = each.value.instance_config.instanceType
  root_volume_size = each.value.instance_config.rootVolumeSize
  root_volume_type = each.value.instance_config.rootVolumeType
  data_volume_size = each.value.instance_config.dataVolumeSize
  data_volume_type = each.value.instance_config.dataVolumeType

  enable_elastic_ip = each.value.enable_elastic_ip

  cpu_threshold = module.config.auto_stop_config.cpuThreshold
  # CloudWatch Alarm は 5 分周期のため、監視期間(分)を期間数に変換
  cpu_evaluation_periods = ceil(module.config.auto_stop_config.cpuEvaluationMinutes / 5)
  scheduled_stop_hour    = module.config.auto_stop_config.scheduledStopHour
  scheduled_stop_minute  = module.config.auto_stop_config.scheduledStopMinute
}
