output "vpc_id" {
  description = "VPC ID"
  value       = module.network.vpc_id
}

output "public_subnet_id" {
  description = "Public Subnet ID"
  value       = module.network.public_subnet_id
}

output "workstations" {
  description = "Per-user workstation information"
  value = {
    for username, ws in module.workstation : username => {
      instance_id       = ws.instance_id
      session_log_group = ws.session_log_group_name
      connect_command   = "aws ssm start-session --target ${ws.instance_id}"
      elastic_ip        = ws.elastic_ip
    }
  }
}
