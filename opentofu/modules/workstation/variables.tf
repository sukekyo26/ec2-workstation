variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "username" {
  description = "Workstation owner username"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID to launch the instance in"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "availability_zone" {
  description = "Availability zone of the subnet (the data volume must be in the same AZ)"
  type        = string
}

variable "root_volume_size" {
  description = "Root EBS volume size (GB)"
  type        = number
}

variable "root_volume_type" {
  description = "Root EBS volume type"
  type        = string
}

variable "data_volume_size" {
  description = "Data EBS volume size (GB)"
  type        = number
}

variable "data_volume_type" {
  description = "Data EBS volume type"
  type        = string
}

variable "user_data_template" {
  description = "Path to the user data script template (rendered with data_volume_id)"
  type        = string
}

variable "enable_elastic_ip" {
  description = "Whether to allocate and associate an Elastic IP"
  type        = bool
}

variable "cpu_threshold" {
  description = "CPU utilization threshold (%) below which the instance is stopped"
  type        = number
}

variable "cpu_evaluation_periods" {
  description = "Number of 5-minute periods the CPU must stay below the threshold"
  type        = number
}

variable "scheduled_stop_hour" {
  description = "Daily scheduled stop hour (0-23, Asia/Tokyo)"
  type        = number
}

variable "scheduled_stop_minute" {
  description = "Daily scheduled stop minute (0-59)"
  type        = number
}
