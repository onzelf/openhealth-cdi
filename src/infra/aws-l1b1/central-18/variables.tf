variable "profile" {
  description = "AWS CLI profile of the governance account (Sandbox-18); set in terraform.tfvars"
  type        = string
}

variable "region" {
  default = "eu-west-2"
}

variable "stack" {
  default = "openhealth-l1b"
}

variable "l1a_stack" {
  description = "L1-A's stack name: its EFS and EFS group are reused, not managed here"
  default     = "openhealth-l1a"
}

variable "governance_host_name" {
  description = "Name tag of the EC2 host that keeps the governance plane (src/infra/aws-l0-host names it openhealth-cdi-l0-host)"
  default     = "openhealth-cdi-l0-host"
}

variable "flower_subnet" {
  description = "ECS subnet of the Flower server in Sandbox-43"
  default     = "10.20.10.0/24"
}

variable "client_subnets" {
  description = "ECS subnet of each client, one per participant account"
  type        = map(string)
  default = {
    A = "10.31.10.0/24" # Sandbox-12
    B = "10.32.10.0/24" # Sandbox-33
    C = "10.33.10.0/24" # Sandbox-8
  }
}

variable "flower_server_repo" {
  default = "fcac/flower-server"
}

variable "flower_client_repo" {
  default = "openhealth/flower-client"
}

variable "flower_account_id" {
  description = "Account ID of Sandbox-43, which pulls the Flower server image"
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.flower_account_id))
    error_message = "An AWS account ID is 12 digits."
  }
}

variable "participant_account_ids" {
  description = "Account IDs of Sandbox-12, -33 and -8 by hospital; they pull the Flower client image and request peerings"
  type        = map(string)
  validation {
    condition     = alltrue([for id in values(var.participant_account_ids) : can(regex("^[0-9]{12}$", id))]) && length(setsubtract(keys(var.participant_account_ids), ["A", "B", "C"])) == 0
    error_message = "Keys A, B and C; each an AWS account ID of 12 digits."
  }
}

variable "governance_domain" {
  description = "L1-A's private zone in this account, which holds fc-hub"
  default     = "openhealth.internal"
}

variable "member_vpc_cidrs" {
  description = "VPC range of each member account, for the accepted peerings and their routes"
  type        = map(string)
  default = {
    flower = "10.20.0.0/16" # Sandbox-43
    A      = "10.31.0.0/16" # Sandbox-12
    B      = "10.32.0.0/16" # Sandbox-33
    C      = "10.33.0.0/16" # Sandbox-8
  }
}

# --- handed over between applies (README, stages 2 and 3) ---

variable "member_vpc_ids" {
  description = "Stage 2: VPC ID of each member account (their vpc_id outputs), to grant openhealth.internal"
  type        = map(string)
  default     = {}
}

variable "accept_peerings" {
  description = "Stage 3: true once the four members have requested their peerings"
  type        = bool
  default     = false
}

variable "flower_zone_id" {
  description = "Stage 3: Sandbox-43's flower_zone_id output, after Sandbox-43 has granted this VPC"
  type        = string
  default     = ""
}
