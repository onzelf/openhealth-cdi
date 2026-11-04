# L1-B1, Sandbox-43 (federation execution): the Flower server in its own account.
#
#   clients A/B/C -> flower-server:8080   from their ECS subnets, over 43<->12/33/8
#   hub           -> flower-server:8081   from the governance host, over 18<->43
#   flower-server -> hub:8080 and /vault  over 18<->43 (admitted by ../central-18)
#
# The Flower server is execution only: it has no rule towards the verifier, the
# issuers, Redis or Hal, and those are not reachable from here.
# Only this account's credentials are used (roadmap v3 6.4): this account requests
# the peering to Sandbox-18 and accepts the three participants' requests.

locals {
  backend_url = "http://flower-server.${var.flower_domain}:8081"
  vault       = var.vault_efs_id != ""

  env = merge({
    HUB_URL                        = var.hub_url
    RUN_ID                         = var.run_id
    BACKEND_URL                    = local.backend_url
    CONTROL_PORT                   = "8081"
    FLOWER_ROUNDS                  = var.flower_rounds
    MIN_CLIENTS                    = "2"
    DEVICE                         = "cpu"
    TRAIN_FRACTION                 = var.train_fraction
    CANCER_SAMPLES_PER_AB_HOSPITAL = var.cancer_samples_per_ab_hospital
    PATHMNIST_PARTITION_PROFILE    = var.pathmnist_partition_profile
    PATHMNIST_PARTITION_SEED       = var.pathmnist_partition_seed
    BATCH_SIZE                     = var.batch_size
    LOCAL_EPOCHS                   = var.local_epochs
    LEARNING_RATE                  = var.learning_rate
    MEDMNIST_ROOT                  = "/tmp/medmnist"
    VAULT_ROOT                     = "/vault"
  }, var.workload == "pathmnist" ? {} : { WORKLOAD = var.workload })
}

module "base" {
  source      = "../modules/base"
  stack       = var.stack
  vpc_cidr    = var.vpc_cidr
  subnet_cidr = var.subnet_cidr
  az_id       = var.az_id
}

# -----------------------------
# Relations into this account, one rule each
# -----------------------------
resource "aws_security_group" "server" {
  name        = "${var.stack}-flower-server"
  description = "Flower server: training from the clients, control from the hub"
  vpc_id      = module.base.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "training" {
  for_each          = var.client_subnets
  security_group_id = aws_security_group.server.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
  description       = "client ${each.key} to the Flower server"
}

resource "aws_vpc_security_group_ingress_rule" "control" {
  security_group_id = aws_security_group.server.id
  cidr_ipv4         = var.hub_cidr
  ip_protocol       = "tcp"
  from_port         = 8081
  to_port           = 8081
  description       = "hub to the Flower control port"
}

# Outbound is open, as in L1-A: ECR, logs and ECS Exec go out through the
# internet gateway, and the receiving side's groups decide what is admitted.
resource "aws_vpc_security_group_egress_rule" "server" {
  security_group_id = aws_security_group.server.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# -----------------------------
# Name: flower-server.flower.openhealth.internal. Cloud Map registers only into
# a namespace of its own account, so this account has its own zone, granted
# below to the governance and participant VPCs (each joins it from its own side).
# -----------------------------
resource "aws_service_discovery_private_dns_namespace" "this" {
  name = var.flower_domain
  vpc  = module.base.vpc_id
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

# -----------------------------
# /vault: L1-A's EFS in Sandbox-18, across the 18<->43 peering.
# The EFS name only resolves in the file system's own VPC, so this account gets
# a private zone with the same name pointing at the mount target's IP. The name
# stays the same, so the TLS check of the EFS mount helper still matches.
# Empty vault_efs_id: no volume, for network checks before /vault is tried.
# -----------------------------
resource "aws_route53_zone" "efs" {
  count = local.vault ? 1 : 0
  name  = "${var.vault_efs_id}.efs.${var.region}.amazonaws.com"
  vpc {
    vpc_id = module.base.vpc_id
  }
}

resource "aws_route53_record" "efs" {
  # the plain name, and any zone-prefixed form the mount helper may use
  for_each = local.vault ? { name = "", wildcard = "*." } : {}
  zone_id  = aws_route53_zone.efs[0].zone_id
  name     = "${each.value}${aws_route53_zone.efs[0].name}"
  type     = "A"
  ttl      = 60
  records  = [var.vault_mount_target_ip]
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
  execution_role_arn       = module.base.execution_role_arn
  task_role_arn            = module.base.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  dynamic "volume" {
    for_each = local.vault ? [1] : []
    content {
      name = "vault"
      efs_volume_configuration {
        file_system_id     = var.vault_efs_id
        transit_encryption = "ENABLED"
        authorization_config {
          access_point_id = var.vault_access_point_id
        }
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
    environment = [for k, v in local.env : { name = k, value = tostring(v) }]
    # Issue #7: only the hub, holding this token, may set the trusted keys.
    secrets     = [{ name = "FLOWER_CONTROL_TOKEN", valueFrom = aws_secretsmanager_secret.control_token.arn }]
    mountPoints = local.vault ? [{ sourceVolume = "vault", containerPath = "/vault", readOnly = false }] : []
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = module.base.log_group
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "flower-server"
      }
    }
  }])
}

resource "aws_ecs_service" "server" {
  name                               = "flower-server"
  cluster                            = module.base.cluster_id
  task_definition                    = aws_ecs_task_definition.server.arn
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  enable_execute_command             = true
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = [module.base.subnet_id]
    security_groups  = [aws_security_group.server.id]
    assign_public_ip = true # no NAT; ingress is the group above
  }

  service_registries {
    registry_arn = aws_service_discovery_service.flower_server.arn
  }

  depends_on = [aws_route53_record.efs]

  lifecycle {
    precondition {
      condition     = var.desired_count == 0 || local.vault
      error_message = "Set the three vault_* variables (README step 7) before starting the server, or it writes to an ephemeral /vault."
    }
  }
}

# -----------------------------
# This side of the peerings and of the shared names (../modules/peer-links)
# -----------------------------
data "aws_caller_identity" "this" {}

module "peer_links" {
  source         = "../modules/peer-links"
  name           = var.stack
  vpc_id         = module.base.vpc_id
  route_table_id = module.base.route_table_id

  # Stage 2: request 43<->18. Stage 3 (after Sandbox-18 accepts): its route.
  requests = var.governance.vpc_id == "" ? {} : {
    governance = {
      account_id = var.governance.account_id
      vpc_id     = var.governance.vpc_id
      cidr       = var.governance.cidr
      active     = var.governance_peering_active
    }
  }

  # Stage 3: accept the three participants' requests, with this side's routes.
  accepts = var.accept_peerings ? {
    for k, id in var.participant_account_ids : k => { account_id = id, cidr = var.participant_vpc_cidrs[k] }
  } : {}

  # Stage 2: let Sandbox-18 and the participants join flower.openhealth.internal.
  zone_id = aws_service_discovery_private_dns_namespace.this.hosted_zone
  grants = merge(
    var.governance.vpc_id == "" ? {} : { governance = var.governance.vpc_id },
    var.participant_vpc_ids,
  )

  # Stage 3: join openhealth.internal in Sandbox-18, so the server resolves fc-hub.
  links = var.governance.zone_id == "" || !var.governance_peering_active ? {} : { governance = var.governance.zone_id }
}
