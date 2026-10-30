output "workstations" {
  description = "Per-user workstation information"
  value = {
    for username, ws in module.workstation : username => {
      instance_name   = ws.instance_name
      instance_id     = ws.instance_id
      data_volume_id  = ws.data_volume_id
      connect_command = "aws ssm start-session --target ${ws.instance_id}"
      elastic_ip      = ws.elastic_ip
    }
  }
}
