output "honua_url" {
  description = "Public URL for the demo environment (https://demo.honua.io once DNS is live)."
  value       = module.honua.service_url
}

output "service_domain_record_fqdn" {
  description = "FQDN of the Route53 alias A record created for demo.honua.io."
  value       = module.honua.service_domain_record_fqdn
}

output "alb_dns_name" {
  description = "Raw ALB DNS name (use for CNAME fallback or health checks before Route53 propagates)."
  value       = module.honua.alb_dns_name
}

output "ecs_cluster_name" {
  description = "ECS cluster name (for aws ecs commands and EventBridge run-task targets)."
  value       = module.honua.ecs_cluster_name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = module.honua.ecs_service_name
}

output "db_endpoint" {
  description = "RDS endpoint (sensitive)."
  value       = module.honua.db_endpoint
  sensitive   = true
}

output "db_connection_secret_arn" {
  description = "Secrets Manager ARN for the database connection string."
  value       = module.honua.db_connection_secret_arn
}

output "admin_password_secret_arn" {
  description = "Secrets Manager ARN for the Honua admin password."
  value       = module.honua.admin_password_secret_arn
}

output "certificate_arn" {
  description = "ACM certificate ARN issued for demo.honua.io."
  value       = module.honua.certificate_arn
}

output "waf_web_acl_arn" {
  description = "ARN of the WAFv2 Web ACL protecting the demo ALB."
  value       = aws_wafv2_web_acl.demo.arn
}

output "control_plane_target_kind" {
  description = "Honua control-plane target kind hint."
  value       = module.honua.control_plane_target_kind
}

output "control_plane_backend_name" {
  description = "Honua control-plane backend identifier hint."
  value       = module.honua.control_plane_backend_name
}
