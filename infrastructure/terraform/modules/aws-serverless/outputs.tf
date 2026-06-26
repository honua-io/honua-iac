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
# The durable GP substrate's runtime contract (v1). Consumers (the honua-devops
# agent / the server) read these ARNs as OPAQUE runtime config — they couple to
# the exported ARNs, NOT to terraform variable names. Null when enable_gp_batch
# is false.

output "gp_batch_enabled" {
  description = "Whether the GP-on-Batch backend was provisioned."
  value       = local.gp_batch_enabled
}

output "gp_job_queue_arn" {
  description = "ARN of the GP Fargate Spot Batch job queue (batch.job_queue_arn)."
  value       = local.gp_batch_enabled ? aws_batch_job_queue.gp[0].arn : null
}

output "gp_job_definition_arns" {
  description = "Map of GP job-definition size tier => ARN ({ s, m, l, xl }); tiers differ only by ephemeral storage. The server selects a tier per job and applies vCPU/memory/timeout/retry as SubmitJob overrides."
  value       = local.gp_batch_enabled ? { for tier, jd in aws_batch_job_definition.gp : tier => jd.arn } : null
}

output "gp_compute_environment_arn" {
  description = "ARN of the GP Fargate Spot Batch compute environment."
  value       = local.gp_batch_enabled ? aws_batch_compute_environment.gp[0].arn : null
}

output "gp_job_role_arn" {
  description = "ARN of the IAM role the running GP container assumes (task/job role)."
  value       = local.gp_batch_enabled ? aws_iam_role.batch_job[0].arn : null
}

output "gp_execution_role_arn" {
  description = "ARN of the Fargate task execution role the GP job definitions use (ECR pull + log writes)."
  value       = local.gp_batch_enabled ? aws_iam_role.batch_execution[0].arn : null
}

output "gp_worker_gdal_repository_url" {
  description = "Push/pull URL of the dedicated worker-gdal ECR repository (null unless create_worker_gdal_repo)."
  value       = var.create_worker_gdal_repo ? aws_ecr_repository.worker_gdal[0].repository_url : null
}

output "gp_batch_workload_id" {
  description = "ControlPlane:ExecutionWorkloads WorkloadId the server uses to select the Batch backend."
  value       = local.gp_batch_enabled ? var.gp_batch_workload_id : null
}

output "gp_batch_control_plane_backend_name" {
  description = "Backend name the reconciler matches to dispatch to the AWS Batch adapter."
  value       = local.gp_batch_enabled ? "honua-aws-batch" : null
}

output "worker_gdal_repository_arn" {
  description = "ARN of the dedicated worker-gdal ECR repository (null unless create_worker_gdal_repo)."
  value       = var.create_worker_gdal_repo ? aws_ecr_repository.worker_gdal[0].arn : null
}

# --- Control-plane event triggers (TriggerMode=Event) outputs --------------
# Null when enable_control_plane_events is false.

output "control_plane_events_enabled" {
  description = "Whether the event-driven control-plane reconcile path was provisioned."
  value       = local.control_plane_events_enabled
}

output "control_plane_reconcile_function_name" {
  description = "Name of the reconcile Lambda (EventBridge Batch-state-change target, HONUA_CONTROL_PLANE_LAMBDA_HANDLER=batch-event)."
  value       = local.control_plane_events_enabled ? aws_lambda_function.control_plane_reconcile[0].function_name : null
}

output "control_plane_reconcile_function_arn" {
  description = "ARN of the reconcile Lambda."
  value       = local.control_plane_events_enabled ? aws_lambda_function.control_plane_reconcile[0].arn : null
}

output "control_plane_backstop_function_name" {
  description = "Name of the backstop Lambda (EventBridge Scheduler rate(2 minutes) target, HONUA_CONTROL_PLANE_LAMBDA_HANDLER=backstop)."
  value       = local.control_plane_events_enabled ? aws_lambda_function.control_plane_backstop[0].function_name : null
}

output "control_plane_backstop_function_arn" {
  description = "ARN of the backstop Lambda."
  value       = local.control_plane_events_enabled ? aws_lambda_function.control_plane_backstop[0].arn : null
}

output "control_plane_batch_event_rule_arn" {
  description = "ARN of the EventBridge rule matching Batch job state changes (drives the reconcile Lambda)."
  value       = local.control_plane_events_enabled ? aws_cloudwatch_event_rule.control_plane_batch_state_change[0].arn : null
}

output "control_plane_tick_function_name" {
  description = "Name of the Phase 3 scheduled-tick Lambda (EventBridge Scheduler target for the PERIODIC ticks, HONUA_CONTROL_PLANE_LAMBDA_HANDLER=scheduled-tick). Null when control-plane events are disabled."
  value       = local.control_plane_events_enabled ? aws_lambda_function.control_plane_tick[0].function_name : null
}

output "control_plane_tick_function_arn" {
  description = "ARN of the Phase 3 scheduled-tick Lambda. Null when control-plane events are disabled."
  value       = local.control_plane_events_enabled ? aws_lambda_function.control_plane_tick[0].arn : null
}

output "control_plane_scheduler_group_name" {
  description = "Name of the EventBridge Scheduler group holding the control-plane backstop + per-kind tick schedules. Null when control-plane events are disabled."
  value       = local.control_plane_events_enabled ? aws_scheduler_schedule_group.control_plane[0].name : null
}

output "control_plane_scheduled_tick_schedule_arns" {
  description = "Map of tick kind -> EventBridge Scheduler schedule ARN for the Phase 3 PERIODIC control-plane ticks. Empty when control-plane events are disabled."
  value       = { for kind, schedule in aws_scheduler_schedule.control_plane_tick : kind => schedule.arn }
}
