# --- Infrastructure outputs ---

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

output "db_endpoint" {
  value     = local.db_endpoint
  sensitive = true
}

output "db_connection_string" {
  value     = local.db_connection_string
  sensitive = true
}

output "db_connection_secret_arn" {
  value = aws_secretsmanager_secret.connection_string.arn
}

output "admin_password_secret_arn" {
  value = aws_secretsmanager_secret.admin_password.arn
}

output "redis_connection_string" {
  value     = local.redis_connection
  sensitive = true
}

output "redis_connection_secret_arn" {
  value     = local.redis_connection != "" ? aws_secretsmanager_secret.redis_connection[0].arn : null
  sensitive = true
}

output "latest_db_snapshot_arn" {
  description = "ARN of the most recent automated PostgreSQL snapshot (if available)."
  value       = local.db_use_existing ? null : try(data.aws_db_snapshot.latest[0].db_snapshot_arn, null)
  sensitive   = true
}

# --- Honua control-plane outputs ---

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

output "operations_metadata" {
  description = "Structured operational metadata for workload, backup/restore, and secret rotation runbooks."
  value = {
    workload = {
      function_name         = aws_lambda_function.this.function_name
      function_arn          = aws_lambda_function.this.arn
      function_version      = aws_lambda_function.this.version
      alias_name            = aws_lambda_alias.live.name
      alias_arn             = aws_lambda_alias.live.arn
      alias_invoke_arn      = aws_lambda_alias.live.invoke_arn
      api_id                = aws_apigatewayv2_api.this.id
      api_execution_arn     = aws_apigatewayv2_api.this.execution_arn
      api_stage_name        = aws_apigatewayv2_stage.this.name
      lambda_log_group_name = aws_cloudwatch_log_group.lambda.name
      api_log_group_name    = aws_cloudwatch_log_group.api_gateway.name
    }
    database = {
      reused                = local.db_use_existing
      engine                = "postgres"
      identifier            = local.db_use_existing ? null : "${local.name}-postgres"
      endpoint              = local.db_endpoint
      database_name         = var.db_name
      username              = var.db_username
      port                  = 5432
      backup_retention_days = local.db_use_existing ? null : (var.environment == "prod" ? 7 : 3)
      multi_az              = local.db_use_existing ? null : var.db_multi_az
      publicly_accessible   = var.db_publicly_accessible
      secret_ref = {
        arn  = aws_secretsmanager_secret.connection_string.arn
        name = aws_secretsmanager_secret.connection_string.name
      }
      backup = {
        retention_days      = local.db_use_existing ? null : (var.environment == "prod" ? 7 : 3)
        latest_snapshot_arn = local.db_use_existing ? null : try(data.aws_db_snapshot.latest[0].db_snapshot_arn, null)
      }
      postgis = {
        enabled                 = var.enable_postgis
        provisioner             = var.enable_postgis ? "postgresql_extension" : null
        readiness_max_attempts  = var.postgis_readiness_max_attempts
        readiness_sleep_seconds = var.postgis_readiness_sleep_seconds
        extensions              = ["postgis", "postgis_raster"]
      }
    }
    cache = {
      enabled            = local.redis_enabled
      reused             = !local.redis_create && local.redis_connection != ""
      identifier         = local.redis_create ? aws_elasticache_replication_group.redis[0].replication_group_id : null
      arn                = local.redis_create ? aws_elasticache_replication_group.redis[0].arn : null
      endpoint           = local.redis_create ? aws_elasticache_replication_group.redis[0].primary_endpoint_address : null
      port               = var.redis_port
      transit_encryption = true
      at_rest_encryption = true
      secret_ref = local.redis_enabled ? {
        arn  = aws_secretsmanager_secret.redis_connection[0].arn
        name = aws_secretsmanager_secret.redis_connection[0].name
      } : null
    }
    secrets = {
      db_connection = {
        arn  = aws_secretsmanager_secret.connection_string.arn
        name = aws_secretsmanager_secret.connection_string.name
      }
      admin_password = {
        arn  = aws_secretsmanager_secret.admin_password.arn
        name = aws_secretsmanager_secret.admin_password.name
      }
      redis_connection = local.redis_enabled ? {
        arn  = aws_secretsmanager_secret.redis_connection[0].arn
        name = aws_secretsmanager_secret.redis_connection[0].name
      } : null
    }
  }
  sensitive = true
}
