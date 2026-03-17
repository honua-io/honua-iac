// Compatibility example wrapper around the canonical customer stack.

module "stack" {
  source = "../../stacks/customer/aws-serverless"

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
  honua_image_uri                 = var.honua_image_uri
  lambda_architectures            = var.lambda_architectures
  lambda_alias_name               = var.lambda_alias_name
  lambda_alias_version            = var.lambda_alias_version
  db_publicly_accessible          = var.db_publicly_accessible
  db_additional_ingress_cidrs     = var.db_additional_ingress_cidrs
  enable_postgis                  = var.enable_postgis
  postgis_readiness_max_attempts  = var.postgis_readiness_max_attempts
  postgis_readiness_sleep_seconds = var.postgis_readiness_sleep_seconds
  redis_enabled                   = var.redis_enabled
  redis_connection_string         = var.redis_connection_string
  redis_connection_cidrs          = var.redis_connection_cidrs
  skip_migrations                 = var.skip_migrations
  tags                            = var.tags
}

output "honua_url" {
  value = module.stack.honua_url
}

output "environment" {
  value = module.stack.environment
}

output "aws_region" {
  value = module.stack.aws_region
}

output "lambda_function_name" {
  value = module.stack.lambda_function_name
}

output "lambda_function_arn" {
  value = module.stack.lambda_function_arn
}

output "lambda_function_version" {
  value = module.stack.lambda_function_version
}

output "lambda_alias_name" {
  value = module.stack.lambda_alias_name
}

output "lambda_alias_arn" {
  value = module.stack.lambda_alias_arn
}

output "lambda_alias_invoke_arn" {
  value = module.stack.lambda_alias_invoke_arn
}

output "lambda_alias_function_version" {
  value = module.stack.lambda_alias_function_version
}

output "control_plane_target_kind" {
  value = module.stack.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.stack.control_plane_backend_name
}

output "control_plane_target_id" {
  value = module.stack.control_plane_target_id
}

output "control_plane_target_name" {
  value = module.stack.control_plane_target_name
}

output "control_plane_target_resource_id" {
  value = module.stack.control_plane_target_resource_id
}

output "control_plane_telemetry_policy" {
  value = module.stack.control_plane_telemetry_policy
}

output "control_plane_current_revision" {
  value = module.stack.control_plane_current_revision
}

output "control_plane_desired_revision" {
  value = module.stack.control_plane_desired_revision
}

output "db_endpoint" {
  value = module.stack.db_endpoint
}

output "redis_connection_string" {
  value = module.stack.redis_connection_string
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
