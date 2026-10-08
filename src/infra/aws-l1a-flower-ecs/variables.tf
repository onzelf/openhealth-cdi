variable "region" {
  default = "eu-west-2"
}

variable "stack" {
  default = "openhealth-l1a"
}

variable "vpc_id" {
  description = "VPC of the L0 host"
}

variable "subnet_ids" {
  description = "Subnets for the Flower tasks and the EFS mount targets"
  type        = list(string)
}

variable "governance_host_instance_id" {
  description = "The EC2 host that keeps the governance plane (hub, gatekeeper, issuers, Redis, Hal)"
}

variable "desired_count" {
  description = "0 parks the Flower tasks without destroying anything"
  type        = number
  default     = 1
}

variable "flower_server_image" {
  description = "Same image as L0's fcac/flower-server:local, pushed to ECR"
}

variable "flower_client_image" {
  description = "Same image as L0's openhealth/flower-client:local, pushed to ECR"
}

# --- same knobs as infra/tofu/main.tf ---

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

variable "org_a_id" {
  default = "org://HospitalA"
}

variable "org_b_id" {
  default = "org://HospitalB"
}

variable "org_c_id" {
  default = "org://HospitalC"
}
