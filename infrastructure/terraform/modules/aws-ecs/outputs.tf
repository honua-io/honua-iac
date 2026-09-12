output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer."
  value       = aws_lb.this.dns_name
}

output "service_url" {
  description = "Convenience URL for the service."
  value       = "${local.service_scheme}://${local.service_host}"
}

output "service_domain_name" {
  description = "Custom service domain name when configured for HTTPS."
  value       = local.use_custom_domain ? var.domain_name : null
}

output "service_domain_record_fqdn" {
  description = "FQDN of the Route53 service alias record when managed by this module."
  value       = local.create_domain_alias ? aws_route53_record.service_alias[0].fqdn : null
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "canary_enabled" {
  description = "Whether ALB canary resources are enabled."
  value       = var.canary_enabled
}

output "canary_ecs_service_name" {
  description = "Canary ECS service name when canary is enabled."
  value       = var.canary_enabled ? aws_ecs_service.canary[0].name : null
}

output "canary_target_group_arn" {
  description = "Canary target group ARN when canary is enabled."
  value       = var.canary_enabled ? aws_lb_target_group.canary[0].arn : null
}

output "canary_weight_percentage" {
  description = "Percentage of default ALB traffic routed to the canary target group."
  value       = var.canary_enabled ? var.canary_weight_percentage : 0
}

output "canary_verification_header_name" {
  description = "HTTP header name that routes requests directly to the canary service."
  value       = var.canary_enabled ? var.canary_header_name : null
}

output "canary_verification_header_value" {
  description = "HTTP header value that routes requests directly to the canary service."
  value       = var.canary_enabled ? var.canary_header_value : null
}

output "control_plane_target_kind" {
  description = "Recommended Honua control-plane deploy target kind for this environment."
  value       = "AwsEcs"
}

output "control_plane_backend_name" {
  description = "Recommended Honua control-plane backend identifier for this environment."
  value       = "honua-gitops-aws-ecs"
}

output "control_plane_telemetry_policy" {
  description = "Recommended deploy telemetry preset for the Honua control plane."
  value       = var.canary_enabled ? "aws-alb-canary" : "honua-http"
}

output "control_plane_telemetry_prometheus_job" {
  description = "Recommended Prometheus job label for stable Honua traffic when wiring control-plane rollback gates."
  value       = "honua"
}

output "control_plane_telemetry_prometheus_canary_job" {
  description = "Recommended Prometheus job label for canary Honua traffic when wiring control-plane rollback gates."
  value       = var.canary_enabled ? "honua-canary" : null
}

output "db_endpoint" {
  description = "RDS endpoint address."
  value       = local.db_endpoint
  sensitive   = true
}

output "db_connection_secret_arn" {
  description = "Secrets Manager ARN for the DB connection string."
  value       = aws_secretsmanager_secret.db_connection.arn
}

output "admin_password_secret_arn" {
  description = "Secrets Manager ARN for the admin password."
  value       = aws_secretsmanager_secret.admin_password.arn
}

output "connection_encryption_master_key_secret_arn" {
  description = "Secrets Manager ARN for the independent connection-encryption master key."
  value       = aws_secretsmanager_secret.master_key.arn
}

output "certificate_arn" {
  description = "ACM certificate ARN in use (if any)."
  value       = local.certificate_arn != "" ? local.certificate_arn : null
}

output "redis_connection_secret_arn" {
  description = "Secrets Manager ARN for the Redis connection string (if set)."
  value       = local.redis_connection != "" ? aws_secretsmanager_secret.redis_connection[0].arn : null
  sensitive   = true
}

output "redis_primary_endpoint" {
  description = "Redis primary endpoint address (if created)."
  value       = local.redis_create ? aws_elasticache_replication_group.redis[0].primary_endpoint_address : null
  sensitive   = true
}

output "multi_node_topology_ready" {
  description = "True when deployment_mode=MultiNode, Redis, and shared AwsS3 file storage are all configured, i.e. more than one task is actually permitted to serve traffic concurrently."
  # local.multi_node_topology_ready is tainted sensitive only because it
  # compares the sensitive redis_connection_string to "", not because
  # readiness itself is secret.
  value = nonsensitive(local.multi_node_topology_ready)
}

output "alb_health_check" {
  description = "ALB target group health check settings that gate traffic to a task (shared by the primary and canary target groups)."
  value = {
    path                = aws_lb_target_group.this.health_check[0].path
    interval_seconds    = aws_lb_target_group.this.health_check[0].interval
    timeout_seconds     = aws_lb_target_group.this.health_check[0].timeout
    healthy_threshold   = aws_lb_target_group.this.health_check[0].healthy_threshold
    unhealthy_threshold = aws_lb_target_group.this.health_check[0].unhealthy_threshold
  }
}

output "container_health_check_start_period_seconds" {
  description = "Container health check warmup window (ECS startPeriod, seconds) before failed health checks count against a task."
  value       = local.container_health_check.startPeriod
}

output "deployment_rollback" {
  description = "The executable rollback actuator backing the protection claim: ECS's native deployment circuit breaker, which stops a rollout and reverts to the last stable task definition if the replacement cannot reach a healthy steady state. Recovery uses ECS's own control plane; no separate controller is retained or required."
  value = {
    mechanism                = "aws-ecs-deployment-circuit-breaker"
    primary_rollback_enabled = aws_ecs_service.this.deployment_circuit_breaker[0].rollback
    canary_rollback_enabled  = local.canary_enabled ? aws_ecs_service.canary[0].deployment_circuit_breaker[0].rollback : null
  }
}

output "task_definition_revision_retention" {
  description = "Prior task definition revision retention policy. This module never deregisters a revision, so every prior revision an operator has run remains registered and selectable for a manual rollback until the operator deregisters it."
  value       = "unbounded-until-manually-deregistered"
}
