variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "username" {
  description = "Workspace owner username"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]{1,30}[a-z0-9]$", var.username))
    error_message = "Username must be 3-32 characters, lowercase alphanumeric with hyphens/underscores, starting and ending with alphanumeric."
  }
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

variable "volume_size" {
  description = "Root EBS volume size (GB)"
  type        = number
}

variable "volume_type" {
  description = "Root EBS volume type"
  type        = string

  validation {
    condition     = contains(["gp3", "gp2"], var.volume_type)
    error_message = "Volume type must be gp3 or gp2."
  }
}

variable "user_data" {
  description = "User data script content"
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
