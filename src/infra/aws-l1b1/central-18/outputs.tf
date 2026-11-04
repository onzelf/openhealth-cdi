output "governance_host_ip" {
  value = data.aws_instance.governance.private_ip
}

output "hub_group" {
  value = aws_security_group.hub.id
}

output "flower_43_vault" {
  description = "Paste into ../flower-43/terraform.tfvars to give the Flower server /vault"
  value       = <<-EOT
    vault_efs_id          = "${data.aws_efs_file_system.vault.id}"
    vault_access_point_id = "${one(data.aws_efs_access_points.vault.ids)}"
    vault_mount_target_ip = "${data.aws_network_interface.vault.private_ip}"
  EOT
}

output "handover" {
  description = "What the other accounts need from this one (README, stage 2)"
  value = {
    account_id = data.aws_caller_identity.this.account_id
    vpc_id     = data.aws_vpc.governance.id
    cidr       = data.aws_vpc.governance.cidr_block
    zone_id    = data.aws_route53_zone.openhealth.zone_id
  }
}

output "peerings_accepted" {
  value = module.peer_links.accepted
}
