output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.this.id
}

output "session_log_group_name" {
  description = "SessionManager log group name"
  value       = aws_cloudwatch_log_group.session_logs.name
}

output "key_pair_id" {
  description = "Key pair ID (private key is stored at /ec2/keypair/{id} in SSM Parameter Store)"
  value       = aws_key_pair.this.key_pair_id
}

output "elastic_ip" {
  description = "Elastic IP address (null if disabled)"
  value       = var.enable_elastic_ip ? aws_eip.this[0].public_ip : null
}
