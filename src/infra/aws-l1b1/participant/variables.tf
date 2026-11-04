# Per hospital, from hospital-a.tfvars, hospital-b.tfvars or hospital-c.tfvars

variable "profile" {
  description = "The participant account's own CLI profile"
}

variable "hospital" {
  description = "A, B or C; must match the workspace (a, b, c)"
  validation {
    condition     = contains(["A", "B", "C"], upper(var.hospital))
    error_message = "hospital must be A, B or C."
  }
}

variable "vpc_cidr" {}

variable "subnet_cidr" {}

# Shared by the three hospitals

variable "region" {
  default = "eu-west-2"
}

variable "stack" {
  default = "openhealth-l1b"
}

variable "az_id" {
  default = "euw2-az2"
}

variable "desired_count" {
  description = "0 builds everything without starting the client; 1 starts it"
  type        = number
  default     = 0
}

variable "flower_client_image" {
  description = "The L1-A image in Sandbox-18's ECR (set in terraform.tfvars)"
}

variable "hub_url" {
  description = "Resolved through L1-A's openhealth.internal zone in Sandbox-18, which this VPC joins at stage 4"
  default     = "http://fc-hub.openhealth.internal:8080"
}

variable "server_address" {
  description = "Resolved through Sandbox-43's flower.openhealth.internal zone, which this VPC joins at stage 4"
  default     = "flower-server.flower.openhealth.internal:8080"
}

# --- same knobs as L1-A ---

variable "compute_backend" {
  default = "cpu"
  validation {
    condition     = lower(var.compute_backend) == "cpu"
    error_message = "Fargate has no GPU. CUDA needs an EC2 capacity provider (later step)."
  }
}

variable "run_id" {
  default = "local-pathmnist-ab-001"
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

# --- peerings and shared names, handed over between applies (README, stages 2 to 4) ---
# Shared by the three hospitals, so they go in terraform.tfvars.

variable "governance" {
  description = "Stage 2: Sandbox-18's handover output"
  type = object({
    account_id = string
    vpc_id     = string
    cidr       = optional(string, "172.31.0.0/16")
    zone_id    = optional(string, "")
  })
  default = { account_id = "", vpc_id = "" }
}

variable "flower" {
  description = "Stage 2: Sandbox-43's handover output"
  type = object({
    account_id = string
    vpc_id     = string
    cidr       = optional(string, "10.20.0.0/16")
    zone_id    = optional(string, "")
  })
  default = { account_id = "", vpc_id = "" }
}

variable "peerings_active" {
  description = "Stage 4: true once Sandbox-18 and Sandbox-43 have accepted this hospital's requests"
  type        = bool
  default     = false
}
