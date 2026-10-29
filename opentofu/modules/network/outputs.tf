output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "public_subnet_id" {
  description = "Public Subnet ID"
  value       = aws_subnet.public.id
}

output "public_subnet_availability_zone" {
  description = "Availability zone of the public subnet"
  value       = aws_subnet.public.availability_zone
}
