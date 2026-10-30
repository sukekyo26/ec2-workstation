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

# LIMIT: opentofu/stacks/workstations/tests は、ここに載せたロール・ポリシーだけを boundary と照らす。aws_iam_* を足したらここにも載せる
output "iam" {
  description = "IAM roles and policies of the module, for opentofu/stacks/workstations/tests"
  value = {
    roles = {
      for k, r in { instance = aws_iam_role.instance, scheduler = aws_iam_role.scheduler } :
      k => { id = r.id, permissions_boundary = r.permissions_boundary, inline_policy = r.inline_policy }
    }
    role_policies = {
      for k, p in { deny_keypair_read = aws_iam_role_policy.deny_keypair_read, scheduler_stop = aws_iam_role_policy.scheduler_stop } :
      k => { role = p.role, policy = p.policy }
    }
    role_policy_attachments = {
      ssm_core = { role = aws_iam_role_policy_attachment.ssm_core.role, policy_arn = aws_iam_role_policy_attachment.ssm_core.policy_arn }
    }
    keypair_parameter_name = aws_ssm_parameter.private_key.name
  }
}
