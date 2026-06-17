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

output "pro_license_enabled" {
  description = "Whether the server is configured to load a signed Pro license from Secrets Manager."
  value       = local.pro_license_enabled
}

output "pro_license_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the signed Pro license envelope (null when enable_pro_license is false)."
  value       = local.pro_license_enabled ? aws_secretsmanager_secret.pro_license[0].arn : null
}

# --- Serverless observability outputs --------------------------------------

output "dashboard_name" {
  description = "Name of the CloudWatch serverless dashboard (null when enable_dashboard is false)."
  value       = var.enable_dashboard ? aws_cloudwatch_dashboard.serverless[0].dashboard_name : null
}

output "dashboard_url" {
  description = "Console URL for the CloudWatch serverless dashboard (null when enable_dashboard is false)."
  value       = var.enable_dashboard ? "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.serverless[0].dashboard_name}" : null
}

output "xray_tracing_enabled" {
  description = "Whether X-Ray active tracing is enabled on the Lambda function."
  value       = var.enable_xray_tracing
}

# --- GP on AWS Batch (Fargate Spot) outputs --------------------------------
# Null when enable_gp_batch is false.

output "gp_batch_enabled" {
  description = "Whether the GP-on-Batch backend was provisioned."
  value       = local.gp_batch_enabled
}

output "gp_batch_job_queue_arn" {
  description = "ARN of the GP Fargate Spot Batch job queue (batch.job_queue_arn)."
  value       = local.gp_batch_enabled ? aws_batch_job_queue.gp[0].arn : null
}

output "gp_batch_job_definition_arn" {
  description = "ARN of the GP Batch job definition, current revision (batch.job_definition_arn)."
  value       = local.gp_batch_enabled ? aws_batch_job_definition.gp[0].arn : null
}

output "gp_batch_compute_environment_arn" {
  description = "ARN of the GP Fargate Spot Batch compute environment."
  value       = local.gp_batch_enabled ? aws_batch_compute_environment.gp[0].arn : null
}

output "gp_batch_job_role_arn" {
  description = "ARN of the IAM role the running GP container assumes."
  value       = local.gp_batch_enabled ? aws_iam_role.batch_job[0].arn : null
}

output "gp_batch_workload_id" {
  description = "ControlPlane:ExecutionWorkloads WorkloadId the server uses to select the Batch backend."
  value       = local.gp_batch_enabled ? var.gp_batch_workload_id : null
}

output "gp_batch_control_plane_backend_name" {
  description = "Backend name the reconciler matches to dispatch to the AWS Batch adapter."
  value       = local.gp_batch_enabled ? "honua-aws-batch" : null
}
