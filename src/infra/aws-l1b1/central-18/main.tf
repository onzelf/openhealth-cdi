# L1-B1, Sandbox-18 (central governance). What governance must allow so that the
# Flower server (Sandbox-43) and the clients (Sandbox-12, -33, -8) can reach it.
# The host, the hub, /vault and L1-A's private zone stay as they are.
#
#   Flower server, clients A/B/C -> hub:8080   a new group on the governance host, one rule per subnet
#   Flower server                -> /vault     one rule on L1-A's EFS group (TCP/2049)
#   member accounts              -> images     ECR repository policies
#
#   Flower, clients A/B/C        -> peerings  accepted here, with this side's routes
#   openhealth.internal (fc-hub) -> granted to their VPCs; this VPC joins
#                                   flower.openhealth.internal (flower-server)
#
# Nothing here opens the verifier, the issuers, Redis or Hal: the host's other
# groups only admit SSH from fixed addresses and L1-A's own Flower group.
# Only this account's credentials are used (roadmap v3 6.4).

data "aws_vpc" "governance" {
  default = true
}

data "aws_instance" "governance" {
  filter {
    name   = "tag:Name"
    values = [var.governance_host_name]
  }
  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]
  }
}

# -----------------------------
# Hub port for the other accounts
# -----------------------------
resource "aws_security_group" "hub" {
  name        = "${var.stack}-governance-link"
  description = "Governance host: hub port for the Flower server and clients in their own accounts"
  vpc_id      = data.aws_vpc.governance.id
}

resource "aws_vpc_security_group_ingress_rule" "hub" {
  for_each          = merge({ "flower server" = var.flower_subnet }, { for k, v in var.client_subnets : "client ${k}" => v })
  security_group_id = aws_security_group.hub.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
  description       = "${each.key} to the hub"
}

# No egress rule: the host's SSH group already allows all outbound, which the
# hub needs for the Flower control port (8081) in Sandbox-43.
resource "aws_network_interface_sg_attachment" "hub" {
  security_group_id    = aws_security_group.hub.id
  network_interface_id = data.aws_instance.governance.network_interface_id
}

# -----------------------------
# /vault for the Flower server: L1-A's EFS, reached over the 18<->43 peering
# -----------------------------
data "aws_efs_file_system" "vault" {
  tags = { Name = "${var.l1a_stack}-vault" }
}

data "aws_efs_access_points" "vault" {
  file_system_id = data.aws_efs_file_system.vault.id
}

data "aws_security_group" "vault" {
  name   = "${var.l1a_stack}-vault"
  vpc_id = data.aws_vpc.governance.id
}

# The mount target in the host's zone (euw2-az2), which is also the zone of the
# Flower subnet, so NFS traffic does not cross zones.
data "aws_network_interface" "vault" {
  filter {
    name   = "description"
    values = ["EFS mount target for ${data.aws_efs_file_system.vault.id}*"]
  }
  filter {
    name   = "availability-zone"
    values = [data.aws_instance.governance.availability_zone]
  }
}

resource "aws_vpc_security_group_ingress_rule" "vault" {
  security_group_id = data.aws_security_group.vault.id
  cidr_ipv4         = var.flower_subnet
  ip_protocol       = "tcp"
  from_port         = 2049
  to_port           = 2049
  description       = "Flower server (Sandbox-43) to /vault"
}

# -----------------------------
# Images: the member accounts pull from this account's ECR
# -----------------------------
locals {
  pullers = {
    (var.flower_server_repo) = [var.flower_account_id]
    (var.flower_client_repo) = values(var.participant_account_ids)
  }
}

# Account principals: each member account decides which of its own roles may
# pull (its task execution role does, through the AWS managed policy).
resource "aws_ecr_repository_policy" "pull" {
  for_each   = local.pullers
  repository = each.key
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "L1BPull"
      Effect    = "Allow"
      Principal = { AWS = [for id in each.value : "arn:aws:iam::${id}:root"] }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    }]
  })
}

# -----------------------------
# This side of the peerings and of the shared names (../modules/peer-links)
# -----------------------------
data "aws_caller_identity" "this" {}

data "aws_route53_zone" "openhealth" {
  name         = var.governance_domain
  private_zone = true
  vpc_id       = data.aws_vpc.governance.id
}

locals {
  member_accounts = merge({ flower = var.flower_account_id }, var.participant_account_ids)
}

module "peer_links" {
  source         = "../modules/peer-links"
  name           = var.stack
  vpc_id         = data.aws_vpc.governance.id
  route_table_id = data.aws_vpc.governance.main_route_table_id

  # Stage 3: accept the four requests (Flower and the three hospitals).
  accepts = var.accept_peerings ? {
    for k, cidr in var.member_vpc_cidrs : k => { account_id = local.member_accounts[k], cidr = cidr }
  } : {}

  # Stage 2: let the four VPCs join openhealth.internal, so they resolve fc-hub.
  zone_id = data.aws_route53_zone.openhealth.zone_id
  grants  = var.member_vpc_ids

  # Stage 3: join Sandbox-43's zone, so the hub resolves flower-server.
  links = var.flower_zone_id == "" ? {} : { flower = var.flower_zone_id }
}
