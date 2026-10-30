variable "resource_prefix" {
  description = "Prefix of the resource names (<projectName>-<environment>)"
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

variable "permissions_boundary_name" {
  description = "Name of the permissions boundary policy that every IAM role of the module gets (cloudformation/permissions-boundary.yaml)"
  type        = string
}
