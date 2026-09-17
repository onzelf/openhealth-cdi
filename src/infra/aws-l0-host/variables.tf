# AWS host configuration. Container deployment is managed separately in src/infra/tofu.

variable "aws_region" {
  description = "AWS region for the L0 host"
  type        = string
  default     = "eu-west-2"
}

variable "aws_profile" {
  description = "Local AWS CLI profile for authentication"
  type        = string
  default     = "sandbox-18"
}

variable "project_name" {
  description = "Resource name prefix"
  type        = string
  default     = "openhealth-cdi-l0"
}

variable "instance_type" {
  description = "EC2 instance type for the L0 host"
  type        = string
  default     = "g5.2xlarge"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB"
  type        = number
  default     = 150
}

# Supply the SSH source address at plan/apply time.
variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH in on port 22, e.g. your_ip/32"
  type        = string

  # Require a single IPv4 address.
  validation {
    condition     = can(cidrnetmask(var.ssh_allowed_cidr)) && endswith(var.ssh_allowed_cidr, "/32")
    error_message = "ssh_allowed_cidr must be a single IPv4 address in /32 form, e.g. 203.0.113.4/32."
  }
}
