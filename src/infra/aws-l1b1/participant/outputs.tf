output "cluster" {
  value = module.base.cluster_name
}

output "service" {
  value = aws_ecs_service.client.name
}

output "vpc_id" {
  value = module.base.vpc_id
}

output "probe_task" {
  description = "Starts a sleeping copy of the client for ECS Exec network checks (README step 8)"
  value = join(" ", [
    "aws ecs run-task --profile ${var.profile} --region ${var.region}",
    "--cluster ${module.base.cluster_name} --task-definition ${aws_ecs_task_definition.client.family}",
    "--launch-type FARGATE --enable-execute-command",
    "--network-configuration 'awsvpcConfiguration={subnets=[${module.base.subnet_id}],securityGroups=[${aws_security_group.client.id}],assignPublicIp=ENABLED}'",
    "--overrides '{\"containerOverrides\":[{\"name\":\"flower-client-${lower(var.hospital)}\",\"command\":[\"sleep\",\"3600\"]}]}'",
  ])
}

output "handover" {
  description = "What Sandbox-18 and Sandbox-43 need from this hospital (README, stage 2)"
  value = {
    account_id = data.aws_caller_identity.this.account_id
    vpc_id     = module.base.vpc_id
  }
}

output "peerings" {
  value = module.peer_links.requested
}
