provider "aws" {
  region = var.region
}

module "honua" {
  source = "../../modules/aws-serverless"

  environment                     = var.environment
  name_prefix                     = var.name_prefix
  existing_vpc_id                 = local.install_net_id
  existing_vpc_cidr               = local.install_net_cidr
  existing_public_subnet_ids      = local.install_net_pub_sub
  existing_private_subnet_ids     = local.install_net_prv_sub
  image                           = local.install_image
  lambda_architectures            = var.lambda_architectures
  lambda_alias_name               = var.lambda_alias_name
  lambda_alias_version            = var.lambda_alias_version
  admin_password                  = var.honua_admin_password
  db_password                     = var.db_password
  existing_db_endpoint            = local.install_db_host
  existing_db_connection_string   = var.existing_db_connection_string
  db_publicly_accessible          = local.install_db_public
  db_additional_ingress_cidrs     = var.db_additional_ingress_cidrs
  enable_postgis                  = local.install_db_postgis
  postgis_readiness_max_attempts  = local.install_db_rdy_max
  postgis_readiness_sleep_seconds = local.install_db_rdy_sleep
  redis_enabled                   = var.redis_enabled
  redis_connection_string         = var.redis_connection_string
  redis_connection_cidrs          = var.redis_connection_cidrs
  skip_migrations                 = var.skip_migrations
  tags                            = var.tags

  enable_dashboard       = var.enable_dashboard
  enable_xray_tracing    = var.enable_xray_tracing
  enable_lambda_insights = var.enable_lambda_insights

  enable_pro_license             = var.enable_pro_license
  pro_license_content            = var.pro_license_content
  pro_license_key_id             = var.pro_license_key_id
  pro_license_trusted_public_key = var.pro_license_trusted_public_key

  enable_bedrock_ai = var.enable_bedrock_ai
  bedrock_ai_model  = var.bedrock_ai_model
  bedrock_ai_region = var.bedrock_ai_region

  enable_control_plane_events            = var.enable_control_plane_events
  control_plane_events_image             = var.control_plane_events_image
  control_plane_events_memory_size       = var.control_plane_events_memory_size
  control_plane_events_timeout_seconds   = var.control_plane_events_timeout_seconds
  control_plane_scheduled_tick_schedules = var.control_plane_scheduled_tick_schedules

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
    Mcp__Profiles__0     = "base"
    Mcp__Profiles__1     = "analysis"
    Mcp__Profiles__2     = "esri-gp"
  }
}

output "dashboard_name" {
  value = module.honua.dashboard_name
}

output "dashboard_url" {
  value = module.honua.dashboard_url
}

output "honua_url" {
  value = module.honua.api_endpoint
}

output "environment" {
  value = module.honua.environment
}

output "aws_region" {
  value = module.honua.aws_region
}

output "lambda_function_name" {
  value = module.honua.lambda_function_name
}

output "lambda_function_arn" {
  value = module.honua.lambda_function_arn
}

output "lambda_function_version" {
  value = module.honua.lambda_function_version
}

output "lambda_alias_name" {
  value = module.honua.lambda_alias_name
}

output "lambda_alias_arn" {
  value = module.honua.lambda_alias_arn
}

output "lambda_alias_invoke_arn" {
  value = module.honua.lambda_alias_invoke_arn
}

output "lambda_alias_function_version" {
  value = module.honua.lambda_alias_function_version
}

output "control_plane_target_kind" {
  value = module.honua.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.honua.control_plane_backend_name
}

output "control_plane_target_id" {
  value = module.honua.control_plane_target_id
}

output "control_plane_target_name" {
  value = module.honua.control_plane_target_name
}

output "control_plane_target_resource_id" {
  value = module.honua.control_plane_target_resource_id
}

output "control_plane_telemetry_policy" {
  value = module.honua.control_plane_telemetry_policy
}

output "control_plane_current_revision" {
  value = module.honua.control_plane_current_revision
}

output "control_plane_desired_revision" {
  value = module.honua.control_plane_desired_revision
}

output "db_endpoint" {
  value     = module.honua.db_endpoint
  sensitive = true
}

output "admin_password_secret_arn" {
  description = "Secrets Manager ARN for the admin password."
  value       = module.honua.admin_password_secret_arn
}

output "redis_connection_string" {
  value     = module.honua.redis_connection_string
  sensitive = true
}

output "pro_license_enabled" {
  value = module.honua.pro_license_enabled
}

output "pro_license_secret_arn" {
  value = module.honua.pro_license_secret_arn
}

output "control_plane_events_enabled" {
  value = module.honua.control_plane_events_enabled
}

output "control_plane_reconcile_function_name" {
  value = module.honua.control_plane_reconcile_function_name
}

output "control_plane_reconcile_function_arn" {
  value = module.honua.control_plane_reconcile_function_arn
}

output "control_plane_backstop_function_name" {
  value = module.honua.control_plane_backstop_function_name
}

output "control_plane_backstop_function_arn" {
  value = module.honua.control_plane_backstop_function_arn
}

output "control_plane_batch_event_rule_arn" {
  value = module.honua.control_plane_batch_event_rule_arn
}
