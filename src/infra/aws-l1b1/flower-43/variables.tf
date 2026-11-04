variable "profile" {
  description = "AWS CLI profile of the Flower account (Sandbox-43); set in terraform.tfvars"
  type        = string
}

variable "region" {
  default = "eu-west-2"
}

variable "stack" {
  default = "openhealth-l1b"
}

variable "vpc_cidr" {
  default = "10.20.0.0/16"
}

variable "subnet_cidr" {
  default = "10.20.10.0/24"
}

variable "az_id" {
  description = "Same zone as the governance host and its EFS mount target (eu-west-2a in all five accounts)"
  default     = "euw2-az2"
}

variable "client_subnets" {
  description = "ECS subnet of each client; each may reach the Flower server on 8080"
  type        = map(string)
  default = {
    A = "10.31.10.0/24" # Sandbox-12
    B = "10.32.10.0/24" # Sandbox-33
    C = "10.33.10.0/24" # Sandbox-8
  }
}

variable "hub_cidr" {
  description = "The governance host's private IP as a /32 (central-18 output governance_host_ip), the only source for the control port"
  type        = string
  validation {
    condition     = can(cidrhost(var.hub_cidr, 0)) && endswith(var.hub_cidr, "/32")
    error_message = "One address as a /32: the governance host's private IP."
  }
}

variable "hub_url" {
  description = "Resolved through L1-A's openhealth.internal zone in Sandbox-18, which this VPC joins at stage 3"
  default     = "http://fc-hub.openhealth.internal:8080"
}

variable "flower_domain" {
  description = "This account's private zone. Not openhealth.internal: one VPC cannot be associated with two private zones of the same name"
  default     = "flower.openhealth.internal"
}

variable "desired_count" {
  description = "0 builds everything without starting the server; 1 starts it"
  type        = number
  default     = 0
}

variable "flower_server_image" {
  description = "The L1-A image in Sandbox-18's ECR"
}

# /vault: values from `terraform output flower_43_vault` in ../central-18.
# Leave vault_efs_id empty to run without /vault (network checks only).
variable "vault_efs_id" {
  default = ""
}

variable "vault_access_point_id" {
  default = ""
}

variable "vault_mount_target_ip" {
  default = ""
}

# --- same knobs as L1-A ---

variable "run_id" {
  default = "local-pathmnist-ab-001"
}

variable "flower_rounds" {
  default = 10
}

variable "local_epochs" {
  default = 1
}

variable "learning_rate" {
  default = 0.001
}

variable "batch_size" {
  default = 32
}

variable "train_fraction" {
  default = 0.80
}

variable "cancer_samples_per_ab_hospital" {
  default = 100
}

variable "pathmnist_partition_profile" {
  default = "COMPLEMENTARY_ABC_V1"
}

variable "pathmnist_partition_seed" {
  default = 20260728
}

variable "workload" {
  default = "pathmnist"
}

# --- peerings and shared names, handed over between applies (README, stages 2 and 3) ---

variable "governance" {
  description = "Stage 2: Sandbox-18's handover output (account_id, vpc_id, cidr, zone_id)"
  type = object({
    account_id = string
    vpc_id     = string
    cidr       = optional(string, "172.31.0.0/16")
    zone_id    = optional(string, "")
  })
  default = { account_id = "", vpc_id = "" }
}

variable "governance_peering_active" {
  description = "Stage 3: true once Sandbox-18 has accepted this account's request"
  type        = bool
  default     = false
}

variable "participant_account_ids" {
  description = "Account ID per hospital, whose peering requests this account accepts"
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for id in values(var.participant_account_ids) : can(regex("^[0-9]{12}$", id))]) && length(setsubtract(keys(var.participant_account_ids), ["A", "B", "C"])) == 0
    error_message = "Keys A, B and C; each an AWS account ID of 12 digits."
  }
}

variable "participant_vpc_cidrs" {
  type = map(string)
  default = {
    A = "10.31.0.0/16" # Sandbox-12
    B = "10.32.0.0/16" # Sandbox-33
    C = "10.33.0.0/16" # Sandbox-8
  }
}

variable "participant_vpc_ids" {
  description = "Stage 2: each hospital's vpc_id output, to grant flower.openhealth.internal"
  type        = map(string)
  default     = {}
}

variable "accept_peerings" {
  description = "Stage 3: true once the three hospitals have requested their peerings"
  type        = bool
  default     = false
}
