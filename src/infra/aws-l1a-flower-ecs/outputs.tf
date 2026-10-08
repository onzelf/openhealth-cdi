output "cluster" {
  value = aws_ecs_cluster.this.name
}

output "vault_efs_id" {
  value       = aws_efs_file_system.vault.id
  description = "Mount this on the host with host/mount-vault.sh"
}

output "hub_name" {
  value = "fc-hub.openhealth.internal -> ${data.aws_instance.governance.private_ip}"
}

output "flower_backend_url" {
  value       = "http://flower-server.openhealth.internal:8081"
  description = "The hub's FLOWER_BACKEND_URL in L1-A (tofu var flower_backend_url on the host)"
}
