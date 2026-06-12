output "environment" {
  value = var.environment
}

output "aws_region" {
  value = data.aws_region.current.name
}

output "api_endpoint" {
  value = aws_apigatewayv2_api.this.api_endpoint
}

output "lambda_function_name" {
  value = aws_lambda_function.this.function_name
}

output "lambda_function_arn" {
  value = aws_lambda_function.this.arn
}

output "lambda_function_version" {
  value = aws_lambda_function.this.version
}

output "lambda_alias_name" {
  value = aws_lambda_alias.live.name
}

output "lambda_alias_arn" {
  value = aws_lambda_alias.live.arn
}

output "lambda_alias_invoke_arn" {
  value = aws_lambda_alias.live.invoke_arn
}

output "lambda_alias_function_version" {
  value = aws_lambda_alias.live.function_version
}

output "control_plane_target_kind" {
  value = "AwsLambda"
}

output "control_plane_backend_name" {
  value = "honua-gitops-aws-lambda"
}

output "control_plane_target_id" {
  value = "${aws_lambda_function.this.function_name}-${aws_lambda_alias.live.name}"
}

output "control_plane_target_name" {
  value = aws_lambda_function.this.function_name
}

output "control_plane_target_resource_id" {
  value = aws_lambda_alias.live.arn
}

output "control_plane_telemetry_policy" {
  value = "honua-http"
}

output "control_plane_current_revision" {
  value = aws_lambda_alias.live.function_version
}

output "control_plane_desired_revision" {
  value = aws_lambda_function.this.version
}

# --- Network outputs (additive) -------------------------------------------
# Exposed so example roots can attach VPC endpoints (e.g. Secrets Manager
# interface endpoint, S3 gateway endpoint) and in-VPC helper resources without
# re-deriving the module's network layout.

output "vpc_id" {
  description = "ID of the VPC the stack runs in (created or existing)."
  value       = local.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC the stack runs in."
  value       = local.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs used by the Lambda function (and RDS unless db_publicly_accessible)."
  value       = local.private_subnets
}

output "private_route_table_ids" {
  description = "Private route table IDs of the module-managed VPC. Empty when reusing an existing VPC (attach gateway endpoints to your own route tables in that case)."
  value       = local.use_existing_vpc ? [] : module.vpc[0].private_route_table_ids
}

output "db_connection_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the database connection string."
  value       = aws_secretsmanager_secret.connection_string.arn
}

output "lambda_security_group_id" {
  description = "Security group ID attached to the Honua Lambda function."
  value       = aws_security_group.lambda.id
}

output "db_endpoint" {
  value     = local.db_endpoint
  sensitive = true
}

output "db_connection_string" {
  value     = local.db_connection_string
  sensitive = true
}

output "redis_connection_string" {
  value     = local.redis_connection
  sensitive = true
}

output "redis_connection_secret_arn" {
  value     = local.redis_connection != "" ? aws_secretsmanager_secret.redis_connection[0].arn : null
  sensitive = true
}

output "db_proxy_endpoint" {
  description = "RDS Proxy endpoint the application connection string uses (null when the proxy is disabled)."
  value       = local.db_proxy_enabled ? aws_db_proxy.db[0].endpoint : null
}
