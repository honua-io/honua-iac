// Pass through the canonical platform/component outputs.

output "alb_dns_name" {
  value = module.platform.alb_dns_name
}

output "service_url" {
  value = module.platform.service_url
}

output "ecs_cluster_name" {
  value = module.platform.ecs_cluster_name
}

output "ecs_service_name" {
  value = module.platform.ecs_service_name
}

output "canary_enabled" {
  value = module.platform.canary_enabled
}

output "canary_ecs_service_name" {
  value = module.platform.canary_ecs_service_name
}

output "canary_target_group_arn" {
  value = module.platform.canary_target_group_arn
}

output "canary_weight_percentage" {
  value = module.platform.canary_weight_percentage
}

output "canary_verification_header_name" {
  value = module.platform.canary_verification_header_name
}

output "canary_verification_header_value" {
  value = module.platform.canary_verification_header_value
}

output "control_plane_target_kind" {
  value = module.platform.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.platform.control_plane_backend_name
}

output "control_plane_telemetry_policy" {
  value = module.platform.control_plane_telemetry_policy
}

output "control_plane_telemetry_prometheus_job" {
  value = module.platform.control_plane_telemetry_prometheus_job
}

output "control_plane_telemetry_prometheus_canary_job" {
  value = module.platform.control_plane_telemetry_prometheus_canary_job
}

output "db_endpoint" {
  value = module.platform.db_endpoint
}

output "db_connection_secret_arn" {
  value = module.platform.db_connection_secret_arn
}

output "admin_password_secret_arn" {
  value = module.platform.admin_password_secret_arn
}

output "certificate_arn" {
  value = module.platform.certificate_arn
}

output "redis_connection_secret_arn" {
  value = module.platform.redis_connection_secret_arn
}

output "redis_primary_endpoint" {
  value = module.platform.redis_primary_endpoint
}
