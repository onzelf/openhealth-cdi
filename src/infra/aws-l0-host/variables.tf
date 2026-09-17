# config knobs. change these (or override via .tfvars) to point the whole
# module at a different account or region later (as discussed 17th sept meeting).
#
# enzo: this lives separately from src/infra/tofu (your docker-only module)
# on purpose - different provider, different blast radius. aws stuff here,
# containers stay over there.

variable "aws_region" {
  description = "AWS region to deploy the L0 host into (London!)"
  type        = string
  default     = "eu-west-2"
}

variable "aws_profile" {
  description = "Local AWS CLI profile to use for authentication (the sandbox, for now)"
  type        = string
  default     = "sandbox-18"
}

variable "project_name" {
  description = "Resource name prefix"
  type        = string
  default     = "openhealth-cdi-l0"
}

# chris/igor: g5.2xlarge matches the L0 spec you reviewed (8 vCPU, 32 GiB)
# RAM, 1x NVIDIA A10G (24 GiB VRAM). flag if this should change later.

variable "instance_type" {
  description = "EC2 instance type for the L0 host (the GPU box)"
  type        = string
  default     = "g5.2xlarge"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB - 150 keeps the whole Docker stack + dataset comfortable"
  type        = number
  default     = 150
}

# no default on purpose - this makes the value a required input at
# plan/apply time, not a stored default. it doesn't by itself stop the
# value from being committed elsewhere (a tracked tfvars file, etc).
variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH in on port 22, e.g. your_ip/32"
  type        = string

  # must be exactly one ipv4 address (/32) - cidrnetmask() only accepts
  # ipv4, so this also rejects ipv6 input.
  validation {
    condition     = can(cidrnetmask(var.ssh_allowed_cidr)) && endswith(var.ssh_allowed_cidr, "/32")
    error_message = "ssh_allowed_cidr must be a single IPv4 address in /32 form, e.g. 203.0.113.4/32."
  }
}
