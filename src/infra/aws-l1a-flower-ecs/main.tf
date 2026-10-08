# L1-A: the Flower execution plane on ECS. The governance plane (hub, gatekeeper,
# issuers, Redis, Hal, UI) stays on the L0 EC2 host, unchanged.
#
# Relations kept from L0:
#   clients -> flower-server:8080      (inside ECS)
#   clients, server -> hub:8080        (ECS -> EC2)
#   hub -> flower-server:8081          (EC2 -> ECS, the control port)
#   server and hub share /vault        (EFS, mounted on both sides)
# Flower gets no route to the gatekeeper, the issuers, Redis or Hal.

data "aws_instance" "governance" {
  instance_id = var.governance_host_instance_id
}

locals {
  domain = "openhealth.internal"

  # The only differences from L0's env: service addresses become VPC names.
  hub_url        = "http://fc-hub.${local.domain}:8080"
  server_grpc    = "flower-server.${local.domain}:8080"
  server_control = "http://flower-server.${local.domain}:8081"

  workload_env = var.workload == "pathmnist" ? [] : ["WORKLOAD=${var.workload}"]

  server_env = concat([
    "HUB_URL=${local.hub_url}",
    "RUN_ID=${var.run_id}",
    "BACKEND_URL=${local.server_control}",
    "CONTROL_PORT=8081",
    "FLOWER_ROUNDS=${var.flower_rounds}",
    "MIN_CLIENTS=2",
    "DEVICE=cpu",
    "TRAIN_FRACTION=${var.train_fraction}",
    "CANCER_SAMPLES_PER_AB_HOSPITAL=${var.cancer_samples_per_ab_hospital}",
    "PATHMNIST_PARTITION_PROFILE=${var.pathmnist_partition_profile}",
    "PATHMNIST_PARTITION_SEED=${var.pathmnist_partition_seed}",
    "BATCH_SIZE=${var.batch_size}",
    "LOCAL_EPOCHS=${var.local_epochs}",
    "LEARNING_RATE=${var.learning_rate}",
    "MEDMNIST_ROOT=/tmp/medmnist",
    "VAULT_ROOT=/vault",
  ], local.workload_env)

  clients = {
    a = { hospital = "A", org = var.org_a_id }
    b = { hospital = "B", org = var.org_b_id }
    c = { hospital = "C", org = var.org_c_id }
  }

  client_env = { for k, c in local.clients : k => concat([
    "HOSPITAL=${c.hospital}",
    "ORG_ID=${c.org}",
    "RUN_ID=${var.run_id}",
    "HUB_URL=${local.hub_url}",
    "SERVER_ADDRESS=${local.server_grpc}",
    "LOCAL_EPOCHS=${var.local_epochs}",
    "LEARNING_RATE=${var.learning_rate}",
    "BATCH_SIZE=${var.batch_size}",
    "TRAIN_FRACTION=${var.train_fraction}",
    "CANCER_SAMPLES_PER_AB_HOSPITAL=${var.cancer_samples_per_ab_hospital}",
    "PATHMNIST_PARTITION_PROFILE=${var.pathmnist_partition_profile}",
    "PATHMNIST_PARTITION_SEED=${var.pathmnist_partition_seed}",
    "MEDMNIST_ROOT=/tmp/medmnist",
    "DEVICE=${lower(var.compute_backend)}",
  ], local.workload_env) }

  to_kv = { for name, lines in merge({ server = local.server_env }, local.client_env) : name => [
    for line in lines : {
      name  = split("=", line)[0]
      value = substr(line, length(split("=", line)[0]) + 1, -1)
    }
  ] }

  logs = {
    logDriver = "awslogs"
    options = {
      "awslogs-group"  = aws_cloudwatch_log_group.this.name
      "awslogs-region" = var.region
    }
  }
}

resource "aws_ecs_cluster" "this" {
  name = var.stack
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.stack}"
  retention_in_days = 14
}

# -----------------------------
# Names: one private DNS zone, readable from ECS tasks and from the EC2 host's
# containers alike (both use the VPC resolver).
# -----------------------------
resource "aws_service_discovery_private_dns_namespace" "this" {
  name = local.domain
  vpc  = var.vpc_id
}

resource "aws_service_discovery_service" "flower_server" {
  name = "flower-server"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this.id
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

resource "aws_service_discovery_service" "hub" {
  name = "fc-hub"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this.id
    dns_records {
      type = "A"
      ttl  = 60
    }
  }
}

resource "aws_service_discovery_instance" "hub" {
  instance_id = var.governance_host_instance_id
  service_id  = aws_service_discovery_service.hub.id
  attributes = {
    AWS_INSTANCE_IPV4 = data.aws_instance.governance.private_ip
  }
}

# -----------------------------
# Network relations
# -----------------------------
resource "aws_security_group" "flower" {
  name        = "${var.stack}-flower"
  description = "Flower execution plane"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "flower_grpc" {
  security_group_id            = aws_security_group.flower.id
  referenced_security_group_id = aws_security_group.flower.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "clients to the Flower server"
}

resource "aws_vpc_security_group_ingress_rule" "flower_control" {
  security_group_id            = aws_security_group.flower.id
  referenced_security_group_id = aws_security_group.governance_link.id
  ip_protocol                  = "tcp"
  from_port                    = 8081
  to_port                      = 8081
  description                  = "hub to the Flower control port"
}

resource "aws_vpc_security_group_egress_rule" "flower" {
  security_group_id = aws_security_group.flower.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Extra group on the EC2 host: only the hub's port, only from Flower.
# Kept separate so the host's own SSH-only group is not touched.
resource "aws_security_group" "governance_link" {
  name        = "${var.stack}-governance-link"
  description = "L0 host: hub port for the Flower execution plane only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "hub_from_flower" {
  security_group_id            = aws_security_group.governance_link.id
  referenced_security_group_id = aws_security_group.flower.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  description                  = "Flower server and clients to the hub"
}

resource "aws_vpc_security_group_egress_rule" "governance_link" {
  security_group_id = aws_security_group.governance_link.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_network_interface_sg_attachment" "governance_link" {
  security_group_id    = aws_security_group.governance_link.id
  network_interface_id = data.aws_instance.governance.network_interface_id
}

# -----------------------------
# Shared /vault: EFS, mounted by the Flower server task and on the host
# (host/mount-vault.sh), so the hub keeps reading the same files.
# -----------------------------
resource "aws_security_group" "efs" {
  name        = "${var.stack}-vault"
  description = "NFS from the Flower server and the governance host"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "efs" {
  for_each = {
    flower = aws_security_group.flower.id
    host   = aws_security_group.governance_link.id
  }
  security_group_id            = aws_security_group.efs.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  description                  = each.key
}

resource "aws_efs_file_system" "vault" {
  encrypted = true
  tags      = { Name = "${var.stack}-vault" }
}

resource "aws_efs_mount_target" "vault" {
  for_each        = toset(var.subnet_ids)
  file_system_id  = aws_efs_file_system.vault.id
  subnet_id       = each.key
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "vault" {
  file_system_id = aws_efs_file_system.vault.id
  root_directory {
    path = "/vault"
    creation_info {
      owner_uid   = 0
      owner_gid   = 0
      permissions = "0755"
    }
  }
}

# -----------------------------
# IAM
# -----------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.stack}-execution"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.stack}-flower"
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

# -----------------------------
# Flower server
# -----------------------------
resource "aws_ecs_task_definition" "server" {
  family                   = "${var.stack}-flower-server"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 4096
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "vault"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.vault.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.vault.id
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "flower-server"
    image     = var.flower_server_image
    essential = true
    portMappings = [
      { containerPort = 8080, protocol = "tcp" },
      { containerPort = 8081, protocol = "tcp" },
    ]
    environment      = local.to_kv.server
    mountPoints      = [{ sourceVolume = "vault", containerPath = "/vault", readOnly = false }]
    logConfiguration = merge(local.logs, { options = merge(local.logs.options, { "awslogs-stream-prefix" = "flower-server" }) })
  }])
}

resource "aws_ecs_service" "server" {
  name                               = "flower-server"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.server.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  enable_execute_command             = true
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.flower.id]
    assign_public_ip = true # no NAT in the sandbox; ingress is the groups above
  }

  service_registries {
    registry_arn = aws_service_discovery_service.flower_server.arn
  }

  depends_on = [aws_efs_mount_target.vault, aws_service_discovery_instance.hub]
}

# -----------------------------
# Flower clients A, B, C (one service each, so each can later move to its own account in L1-B)
# -----------------------------
resource "aws_ecs_task_definition" "client" {
  for_each                 = local.clients
  family                   = "${var.stack}-flower-client-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 2048
  memory                   = 4096
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name             = "flower-client-${each.key}"
    image            = var.flower_client_image
    essential        = true
    environment      = local.to_kv[each.key]
    logConfiguration = merge(local.logs, { options = merge(local.logs.options, { "awslogs-stream-prefix" = "flower-client-${each.key}" }) })
  }])
}

resource "aws_ecs_service" "client" {
  for_each                           = local.clients
  name                               = "flower-client-${each.key}"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.client[each.key].arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  enable_execute_command             = true
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.flower.id]
    assign_public_ip = true
  }

  depends_on = [aws_ecs_service.server]
}
