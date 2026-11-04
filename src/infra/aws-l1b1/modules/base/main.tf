# What every new L1-B account has in common: one VPC with one ECS subnet, an
# ECS cluster with its log group, and the two task roles.
#
# No NAT gateway: as in L1-A, tasks get a public IP for ECR, CloudWatch Logs,
# ECS Exec and the MedMNIST download. Nothing can come in that way, because
# each root's security groups only admit the peered ranges.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "stack" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "subnet_cidr" {
  type = string
}

variable "az_id" {
  description = "Zone ID, not name: IDs are the same physical zone in every account"
  type        = string
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # both are needed for private hosted zones
  tags                 = { Name = var.stack }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.stack }
}

# The subnet stays on the main route table, as in the default VPC of Sandbox-18,
# so each account's peer-links module adds its peering routes there.
resource "aws_route" "internet" {
  route_table_id         = aws_vpc.this.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_subnet" "ecs" {
  vpc_id               = aws_vpc.this.id
  cidr_block           = var.subnet_cidr
  availability_zone_id = var.az_id
  tags                 = { Name = "${var.stack}-ecs" }
}

resource "aws_ecs_cluster" "this" {
  name = var.stack
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.stack}"
  retention_in_days = 14
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Pulls the images from the ECR repositories in Sandbox-18. The managed policy
# allows the ECR reads on any repository; Sandbox-18's repository policy decides
# whether this account may read its repositories (../../central-18).
resource "aws_iam_role" "execution" {
  name               = "${var.stack}-execution"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The task itself only needs ECS Exec.
resource "aws_iam_role" "task" {
  name               = "${var.stack}-task"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "task_exec" {
  name = "ecs-exec"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel", "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"]
      Resource = "*"
    }]
  })
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "subnet_id" {
  value = aws_subnet.ecs.id
}

output "route_table_id" {
  value = aws_vpc.this.main_route_table_id
}

output "cluster_id" {
  value = aws_ecs_cluster.this.id
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.this.name
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}
