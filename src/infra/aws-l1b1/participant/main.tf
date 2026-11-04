# L1-B1, one participant account (Sandbox-12, -33 or -8): one Flower client,
# applied by the organisation in its own account, with its own credentials and
# its own state (one workspace per hospital: a, b, c).
#
#   client -> flower-server:8080   in Sandbox-43, over 43<->this account
#   client -> hub:8080             in Sandbox-18, over 18<->this account
#
# Nothing comes in: the client's group has no ingress rule. There is no peering
# to another participant, so no route to one either. This account requests its
# two peerings itself (roadmap v3 6.4: own credentials, own state).

locals {
  hospital = upper(var.hospital)

  env = merge({
    HOSPITAL                       = local.hospital
    ORG_ID                         = "org://Hospital${local.hospital}"
    RUN_ID                         = var.run_id
    HUB_URL                        = var.hub_url
    SERVER_ADDRESS                 = var.server_address
    LOCAL_EPOCHS                   = var.local_epochs
    LEARNING_RATE                  = var.learning_rate
    BATCH_SIZE                     = var.batch_size
    TRAIN_FRACTION                 = var.train_fraction
    CANCER_SAMPLES_PER_AB_HOSPITAL = var.cancer_samples_per_ab_hospital
    PATHMNIST_PARTITION_PROFILE    = var.pathmnist_partition_profile
    PATHMNIST_PARTITION_SEED       = var.pathmnist_partition_seed
    MEDMNIST_ROOT                  = "/tmp/medmnist"
    DEVICE                         = lower(var.compute_backend)
  }, var.workload == "pathmnist" ? {} : { WORKLOAD = var.workload })
}

module "base" {
  source      = "../modules/base"
  stack       = var.stack
  vpc_cidr    = var.vpc_cidr
  subnet_cidr = var.subnet_cidr
  az_id       = var.az_id
}

resource "aws_security_group" "client" {
  name        = "${var.stack}-flower-client"
  description = "Flower client ${local.hospital}: outbound only"
  vpc_id      = module.base.vpc_id

  lifecycle {
    precondition {
      condition     = terraform.workspace == lower(var.hospital)
      error_message = "Select the workspace that matches the var file: terraform workspace select ${lower(var.hospital)}"
    }
  }
}

# Outbound is open, as in L1-A (ECR, logs, ECS Exec, the MedMNIST download).
# What the client may reach in the other accounts is decided there.
resource "aws_vpc_security_group_egress_rule" "client" {
  security_group_id = aws_security_group.client.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_ecs_task_definition" "client" {
  family                   = "${var.stack}-flower-client-${lower(var.hospital)}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 2048
  memory                   = 4096
  execution_role_arn       = module.base.execution_role_arn
  task_role_arn            = module.base.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name        = "flower-client-${lower(var.hospital)}"
    image       = var.flower_client_image
    essential   = true
    environment = [for k, v in local.env : { name = k, value = tostring(v) }]
    # Issue #7: this hospital's Flower execution key, from this account's Secrets Manager.
    secrets = [{ name = "EXECUTION_KEY_HEX", valueFrom = aws_secretsmanager_secret.execution_key.arn }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = module.base.log_group
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "flower-client-${lower(var.hospital)}"
      }
    }
  }])
}

resource "aws_ecs_service" "client" {
  name                               = "flower-client-${lower(var.hospital)}"
  cluster                            = module.base.cluster_id
  task_definition                    = aws_ecs_task_definition.client.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  enable_execute_command             = true
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = [module.base.subnet_id]
    security_groups  = [aws_security_group.client.id]
    assign_public_ip = true
  }
}

# -----------------------------
# This side of the peerings and of the shared names (../modules/peer-links)
# -----------------------------
data "aws_caller_identity" "this" {}

locals {
  peers = { for k, v in { governance = var.governance, flower = var.flower } : k => v if v.vpc_id != "" }
}

module "peer_links" {
  source         = "../modules/peer-links"
  name           = "${var.stack}-${lower(var.hospital)}"
  vpc_id         = module.base.vpc_id
  route_table_id = module.base.route_table_id

  # Stage 2: request this account <-> 18 and <-> 43. Stage 4 (after both
  # accepted): the two routes.
  requests = {
    for k, v in local.peers : k => {
      account_id = v.account_id
      vpc_id     = v.vpc_id
      cidr       = v.cidr
      active     = var.peerings_active
    }
  }

  # Stage 4: join both zones, so the client resolves fc-hub and flower-server.
  links = var.peerings_active ? { for k, v in local.peers : k => v.zone_id if v.zone_id != "" } : {}
}
