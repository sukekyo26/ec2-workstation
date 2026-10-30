output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "public_subnet_id" {
  description = "Public Subnet ID"
  value       = aws_subnet.public.id
}

# LIMIT: opentofu/stacks/workstations/tests は、ここに載せたロール・ポリシーだけを boundary と照らす。aws_iam_* を足したらここにも載せる
output "iam" {
  description = "IAM roles and policies of the module, for opentofu/stacks/workstations/tests"
  value = {
    roles = {
      for k, r in { flow_logs = aws_iam_role.flow_logs } :
      k => { id = r.id, name = r.name, permissions_boundary = r.permissions_boundary, inline_policy = r.inline_policy }
    }
    role_policies = {
      for k, p in { flow_logs_write = aws_iam_role_policy.flow_logs_write } :
      k => { role = p.role, policy = p.policy }
    }
    role_policy_attachments = {}
  }
}
