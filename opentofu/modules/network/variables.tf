variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "vpc_name" {
  description = "Name tag of the VPC (the workstations root looks the VPC up by it)"
  type        = string
}

variable "public_subnet_name" {
  description = "Name tag of the public subnet (the workstations root looks the subnet up by it)"
  type        = string
}
