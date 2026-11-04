# One account's own side of its VPC peerings and shared private zones.
# Roadmap v3 6.4: each account is applied with its own credentials and Terraform
# state, and no role in one account administers another. So every root uses this
# module with its own provider only; values from other accounts come in as plain
# variables (VPC IDs, account IDs, zone IDs), handed over between applies.
#
#   requests  peerings this account asks for. The route is only added once the
#             other side has accepted (active = true on a later apply).
#   accepts   peerings this account accepts. Each is found by the requesting
#             account, its range and this VPC, so only the expected request is
#             accepted.
#   grants    other accounts' VPCs allowed to join this account's private zone.
#   links     other accounts' private zones this VPC joins (after their grant).
#
# Routes only cover the other side's range, so nothing transits: no
# participant-to-participant path exists.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "route_table_id" {
  type = string
}

variable "requests" {
  type = map(object({
    account_id = string
    vpc_id     = string
    cidr       = string
    active     = optional(bool, false)
  }))
  default = {}
}

variable "accepts" {
  type = map(object({
    account_id = string
    cidr       = string
  }))
  default = {}
}

variable "zone_id" {
  description = "This account's private zone, for grants"
  type        = string
  default     = ""
}

variable "grants" {
  description = "name => VPC ID in another account"
  type        = map(string)
  default     = {}
}

variable "links" {
  description = "name => private zone ID in another account"
  type        = map(string)
  default     = {}
}

resource "aws_vpc_peering_connection" "request" {
  for_each      = var.requests
  vpc_id        = var.vpc_id
  peer_vpc_id   = each.value.vpc_id
  peer_owner_id = each.value.account_id
  tags          = { Name = "${var.name}-${each.key}" }
}

resource "aws_route" "request" {
  for_each                  = { for k, v in var.requests : k => v if v.active }
  route_table_id            = var.route_table_id
  destination_cidr_block    = each.value.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.request[each.key].id
}

data "aws_vpc_peering_connection" "accept" {
  for_each = var.accepts
  filter {
    name   = "requester-vpc-info.owner-id"
    values = [each.value.account_id]
  }
  filter {
    name   = "requester-vpc-info.cidr-block"
    values = [each.value.cidr]
  }
  filter {
    name   = "accepter-vpc-info.vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "status-code"
    values = ["pending-acceptance", "active"]
  }
}

resource "aws_vpc_peering_connection_accepter" "accept" {
  for_each                  = var.accepts
  vpc_peering_connection_id = data.aws_vpc_peering_connection.accept[each.key].id
  auto_accept               = true
  tags                      = { Name = "${var.name}-${each.key}" }
}

resource "aws_route" "accept" {
  for_each                  = var.accepts
  route_table_id            = var.route_table_id
  destination_cidr_block    = each.value.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.accept[each.key].id
}

resource "aws_route53_vpc_association_authorization" "grant" {
  for_each = var.grants
  zone_id  = var.zone_id
  vpc_id   = each.value
}

resource "aws_route53_zone_association" "link" {
  for_each = var.links
  zone_id  = each.value
  vpc_id   = var.vpc_id
}

output "requested" {
  description = "name => peering ID, for the record"
  value       = { for k, v in aws_vpc_peering_connection.request : k => v.id }
}

output "accepted" {
  value = { for k, v in aws_vpc_peering_connection_accepter.accept : k => v.id }
}
