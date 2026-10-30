output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.this.id
}

output "instance_name" {
  description = "EC2 instance Name tag (stable across AMI updates, used by scripts/ to look up the instance ID)"
  value       = aws_instance.this.tags.Name
}

output "data_volume_id" {
  description = "Data EBS volume ID"
  value       = aws_ebs_volume.data.id
}

output "key_pair_id" {
  description = "Key pair ID (private key is stored at /ec2/keypair/{id} in SSM Parameter Store)"
  value       = aws_key_pair.this.key_pair_id
}

output "elastic_ip" {
  description = "Elastic IP address (null if disabled)"
  value       = var.enable_elastic_ip ? aws_eip.this[0].public_ip : null
}
