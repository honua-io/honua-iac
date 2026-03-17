// Compatibility example wrapper around the canonical customer stack.

module "stack" {
  source = "../../stacks/customer/aws"

  region                          = var.region
  environment                     = var.environment
  name_prefix                     = var.name_prefix
  existing_vpc_id                 = var.existing_vpc_id
  existing_vpc_cidr               = var.existing_vpc_cidr
  existing_public_subnet_ids      = var.existing_public_subnet_ids
  existing_private_subnet_ids     = var.existing_private_subnet_ids
  honua_admin_password            = var.honua_admin_password
  db_password                     = var.db_password
  existing_db_endpoint            = var.existing_db_endpoint
  existing_db_connection_string   = var.existing_db_connection_string
  honua_image                     = var.honua_image
  task_cpu_architecture           = var.task_cpu_architecture
  db_publicly_accessible          = var.db_publicly_accessible
  db_additional_ingress_cidrs     = var.db_additional_ingress_cidrs
  enable_postgis                  = var.enable_postgis
  postgis_readiness_max_attempts  = var.postgis_readiness_max_attempts
  postgis_readiness_sleep_seconds = var.postgis_readiness_sleep_seconds
  redis_enabled                   = var.redis_enabled
  redis_connection_string         = var.redis_connection_string
  redis_connection_cidrs          = var.redis_connection_cidrs
  desired_count                   = var.desired_count
  canary_enabled                  = var.canary_enabled
  canary_image                    = var.canary_image
  canary_desired_count            = var.canary_desired_count
  canary_weight_percentage        = var.canary_weight_percentage
  alb_deletion_protection         = var.alb_deletion_protection
  alb_access_logs_enabled         = var.alb_access_logs_enabled
  alb_access_logs_force_destroy   = var.alb_access_logs_force_destroy
  alb_certificate_arn             = var.alb_certificate_arn
  allow_http_ingress_cidrs        = var.allow_http_ingress_cidrs
  waf_web_acl_arn                 = var.waf_web_acl_arn
  tags                            = var.tags
}

output "honua_url" {
  value = module.stack.honua_url
}

output "ecs_cluster_name" {
  value = module.stack.ecs_cluster_name
}

output "ecs_service_name" {
  value = module.stack.ecs_service_name
}

output "canary_enabled" {
  value = module.stack.canary_enabled
}

output "canary_ecs_service_name" {
  value = module.stack.canary_ecs_service_name
}

output "canary_verification_header_name" {
  value = module.stack.canary_verification_header_name
}

output "canary_verification_header_value" {
  value = module.stack.canary_verification_header_value
}

output "control_plane_target_kind" {
  value = module.stack.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.stack.control_plane_backend_name
}

output "control_plane_telemetry_policy" {
  value = module.stack.control_plane_telemetry_policy
}

output "control_plane_telemetry_prometheus_job" {
  value = module.stack.control_plane_telemetry_prometheus_job
}

output "control_plane_telemetry_prometheus_canary_job" {
  value = module.stack.control_plane_telemetry_prometheus_canary_job
}

output "db_endpoint" {
  value = module.stack.db_endpoint
}

output "redis_primary_endpoint" {
  value = module.stack.redis_primary_endpoint
}

output "infrastructure_outputs" {
  value = module.stack.infrastructure_outputs
}

output "infrastructure_secrets" {
  value = module.stack.infrastructure_secrets
}

output "honua_integration_outputs" {
  value = module.stack.honua_integration_outputs
}

output "deployment_contract" {
  value = module.stack.deployment_contract
}

output "validation_contract" {
  value = module.stack.validation_contract
}

output "operations_contract" {
  value = module.stack.operations_contract
}
