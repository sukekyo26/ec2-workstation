output "vpc_id" {
  description = "VPC ID"
  value       = module.network.vpc_id
}

output "public_subnet_id" {
  description = "Public Subnet ID"
  value       = module.network.public_subnet_id
}
