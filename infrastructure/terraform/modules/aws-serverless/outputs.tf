// Pass through the canonical platform/component outputs.

output "environment" {
  value = module.platform.environment
}

output "aws_region" {
  value = module.platform.aws_region
}

output "api_endpoint" {
  value = module.platform.api_endpoint
}

output "lambda_function_name" {
  value = module.platform.lambda_function_name
}

output "lambda_function_arn" {
  value = module.platform.lambda_function_arn
}

output "lambda_function_version" {
  value = module.platform.lambda_function_version
}

output "lambda_alias_name" {
  value = module.platform.lambda_alias_name
}

output "lambda_alias_arn" {
  value = module.platform.lambda_alias_arn
}

output "lambda_alias_invoke_arn" {
  value = module.platform.lambda_alias_invoke_arn
}

output "lambda_alias_function_version" {
  value = module.platform.lambda_alias_function_version
}

output "control_plane_target_kind" {
  value = module.platform.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.platform.control_plane_backend_name
}

output "control_plane_target_id" {
  value = module.platform.control_plane_target_id
}

output "control_plane_target_name" {
  value = module.platform.control_plane_target_name
}

output "control_plane_target_resource_id" {
  value = module.platform.control_plane_target_resource_id
}

output "control_plane_telemetry_policy" {
  value = module.platform.control_plane_telemetry_policy
}

output "control_plane_current_revision" {
  value = module.platform.control_plane_current_revision
}

output "control_plane_desired_revision" {
  value = module.platform.control_plane_desired_revision
}

output "db_endpoint" {
  value = module.platform.db_endpoint
}

output "db_connection_string" {
  value = module.platform.db_connection_string
}

output "redis_connection_string" {
  value = module.platform.redis_connection_string
}

output "redis_connection_secret_arn" {
  value = module.platform.redis_connection_secret_arn
}
