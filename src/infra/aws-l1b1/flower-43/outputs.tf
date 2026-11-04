output "cluster" {
  value = module.base.cluster_name
}

output "vpc_id" {
  value = module.base.vpc_id
}

output "flower_backend_url" {
  description = "The hub's FLOWER_BACKEND_URL in L1-B1 (tofu var flower_backend_url on the host), and the tests' FLOWER_URL"
  value       = local.backend_url
}

output "server_address" {
  description = "The clients' SERVER_ADDRESS"
  value       = "flower-server.${var.flower_domain}:8080"
}

output "flower_zone_id" {
  value = aws_service_discovery_private_dns_namespace.this.hosted_zone
}

output "probe_task" {
  description = "Starts a sleeping copy of the server for ECS Exec checks; with /vault set, it also tests the EFS mount (README step 7)"
  value = join(" ", [
    "aws ecs run-task --profile ${var.profile} --region ${var.region}",
    "--cluster ${module.base.cluster_name} --task-definition ${aws_ecs_task_definition.server.family}",
    "--launch-type FARGATE --enable-execute-command",
    "--network-configuration 'awsvpcConfiguration={subnets=[${module.base.subnet_id}],securityGroups=[${aws_security_group.server.id}],assignPublicIp=ENABLED}'",
    "--overrides '{\"containerOverrides\":[{\"name\":\"flower-server\",\"command\":[\"sleep\",\"3600\"]}]}'",
  ])
}

output "handover" {
  description = "What the other accounts need from this one (README, stage 2)"
  value = {
    account_id = data.aws_caller_identity.this.account_id
    vpc_id     = module.base.vpc_id
    cidr       = var.vpc_cidr
    zone_id    = aws_service_discovery_private_dns_namespace.this.hosted_zone
  }
}

output "peerings" {
  value = { requested = module.peer_links.requested, accepted = module.peer_links.accepted }
}
