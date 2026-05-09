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
