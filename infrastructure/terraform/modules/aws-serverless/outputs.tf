# --- Infrastructure outputs ---

output "environment" {
  description = "Deployment environment label used for control-plane target IDs."
  value       = var.environment
}

output "aws_region" {
  description = "AWS region hosting the serverless deployment."
  value       = data.aws_region.current.id
}

output "api_endpoint" {
  description = "Base HTTPS endpoint for the deployed API Gateway HTTP API."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "lambda_function_name" {
  description = "Name of the primary Lambda function."
  value       = aws_lambda_function.this.function_name
}

output "lambda_function_arn" {
  description = "ARN of the primary Lambda function."
  value       = aws_lambda_function.this.arn
}

output "lambda_function_version" {
  description = "Published version of the current Lambda function deployment package."
  value       = aws_lambda_function.this.version
}

output "lambda_alias_name" {
  description = "Name of the live Lambda alias used for stable traffic routing."
  value       = aws_lambda_alias.live.name
}

output "lambda_alias_arn" {
  description = "ARN of the live Lambda alias."
  value       = aws_lambda_alias.live.arn
}

output "lambda_alias_invoke_arn" {
  description = "Invoke ARN of the live Lambda alias."
  value       = aws_lambda_alias.live.invoke_arn
}

output "lambda_alias_function_version" {
  description = "Lambda function version currently targeted by the live alias."
  value       = aws_lambda_alias.live.function_version
}

output "db_endpoint" {
  description = "Database endpoint host used by the runtime."
  value       = local.db_endpoint
  sensitive   = true
}

output "db_connection_string" {
  description = "Resolved runtime PostgreSQL connection string."
  value       = local.db_connection_string
  sensitive   = true
}

output "db_connection_secret_arn" {
  description = "ARN of the Secrets Manager secret storing the runtime database connection string."
  value       = aws_secretsmanager_secret.connection_string.arn
}

output "admin_password_secret_arn" {
  description = "ARN of the Secrets Manager secret storing the Honua admin password."
  value       = aws_secretsmanager_secret.admin_password.arn
}

output "connection_encryption_master_key_secret_arn" {
  description = "ARN of the Secrets Manager secret storing the connection encryption master key."
  value       = aws_secretsmanager_secret.connection_encryption_master_key.arn
}

output "redis_connection_string" {
  description = "Resolved Redis connection string when Redis is enabled or reused."
  value       = local.redis_connection
  sensitive   = true
}

output "redis_connection_secret_arn" {
  description = "ARN of the Secrets Manager secret storing the Redis connection string when Redis is enabled."
  value       = local.redis_connection != "" ? aws_secretsmanager_secret.redis_connection[0].arn : null
  sensitive   = true
}

output "latest_db_snapshot_arn" {
  description = "ARN of the most recent automated PostgreSQL snapshot (if available)."
  value       = local.db_use_existing ? null : try(data.aws_db_snapshot.latest[0].db_snapshot_arn, null)
  sensitive   = true
}

output "app_storage_enabled" {
  description = "Whether application S3 storage is enabled."
  value       = var.app_storage_enabled
}

output "app_storage_bucket_name" {
  description = "Application S3 bucket name when storage is enabled."
  value       = var.app_storage_enabled ? aws_s3_bucket.app_storage[0].bucket : null
}

output "app_storage_bucket_arn" {
  description = "Application S3 bucket ARN when storage is enabled."
  value       = var.app_storage_enabled ? aws_s3_bucket.app_storage[0].arn : null
}

output "app_storage_prefix" {
  description = "Application S3 key prefix used for validation probes."
  value       = var.app_storage_enabled ? local.app_storage_prefix : null
}

# --- Honua control-plane outputs ---

output "control_plane_target_kind" {
  description = "Honua control-plane deploy target kind for this runtime."
  value       = "AwsLambda"
}

output "control_plane_backend_name" {
  description = "Honua control-plane deploy backend name for AWS Lambda."
  value       = "honua-gitops-aws-lambda"
}

output "control_plane_contract_version" {
  description = "Schema version for the unified Honua control-plane contract."
  value       = "v2"
}

output "control_plane_target_id" {
  description = "Stable control-plane target identifier combining function name and live alias."
  value       = "${aws_lambda_function.this.function_name}-${aws_lambda_alias.live.name}"
}

output "control_plane_target_name" {
  description = "Human-readable control-plane target name."
  value       = aws_lambda_function.this.function_name
}

output "control_plane_target_resource_id" {
  description = "Provider resource identifier for the active deploy target."
  value       = aws_lambda_alias.live.arn
}

output "control_plane_target_resource_group" {
  description = "Logical resource group for the target when the provider supports it."
  value       = null
}

output "control_plane_telemetry_policy" {
  description = "Default Honua telemetry policy used for deploy health evaluation."
  value       = "honua-http"
}

output "control_plane_current_revision" {
  description = "Currently routed Lambda version."
  value       = aws_lambda_alias.live.function_version
}

output "control_plane_desired_revision" {
  description = "Desired Lambda version produced by the current apply."
  value       = aws_lambda_function.this.version
}

output "control_plane_current_image" {
  description = "Current container image reference for the live workload."
  value       = var.image
}

output "control_plane_desired_image" {
  description = "Desired container image reference for the workload."
  value       = var.image
}

output "marketplace_profile" {
  description = "Machine-readable marketplace deployment support profile."
  value = {
    schema_version  = "v1"
    eligible        = false
    turnkey_runtime = true
    bundle_profile  = "operator-only"
    target_family   = "aws-serverless"
    blocker_reason  = "Serverless runtime targets are excluded from marketplace-targeted bundles; prefer aws-ecs."
  }
}

output "control_plane_contract" {
  description = "Unified control-plane contract for deploy automation and marketplace packaging."
  value = nonsensitive({
    schema_version = "v2"
    backend_name   = "honua-gitops-aws-lambda"
    target_kind    = "AwsLambda"
    target_id      = "${aws_lambda_function.this.function_name}-${aws_lambda_alias.live.name}"
    target_name    = aws_lambda_function.this.function_name
    resource_id    = aws_lambda_alias.live.arn
    resource_group = null
    endpoint       = aws_apigatewayv2_api.this.api_endpoint
    artifact_reference = {
      kind    = "container-image"
      current = var.image
      desired = var.image
    }
    current_revision = aws_lambda_alias.live.function_version
    desired_revision = aws_lambda_function.this.version
    secret_refs = {
      secret_store = {
        kind           = "aws-secrets-manager"
        id             = data.aws_region.current.id
        name           = null
        versionless_id = null
      }
      admin_password = {
        kind           = "aws-secrets-manager"
        id             = aws_secretsmanager_secret.admin_password.arn
        name           = aws_secretsmanager_secret.admin_password.name
        versionless_id = null
      }
      connection_encryption_master_key = {
        kind           = "aws-secrets-manager"
        id             = aws_secretsmanager_secret.connection_encryption_master_key.arn
        name           = aws_secretsmanager_secret.connection_encryption_master_key.name
        versionless_id = null
      }
      database_connection = {
        kind           = "aws-secrets-manager"
        id             = aws_secretsmanager_secret.connection_string.arn
        name           = aws_secretsmanager_secret.connection_string.name
        versionless_id = null
      }
      redis_connection = local.redis_enabled ? {
        kind           = "aws-secrets-manager"
        id             = aws_secretsmanager_secret.redis_connection[0].arn
        name           = aws_secretsmanager_secret.redis_connection[0].name
        versionless_id = null
      } : null
      registry_pull = null
    }
    object_storage_refs = {
      enabled              = var.app_storage_enabled
      kind                 = "aws-s3"
      bucket_name          = var.app_storage_enabled ? aws_s3_bucket.app_storage[0].bucket : null
      bucket_arn           = var.app_storage_enabled ? aws_s3_bucket.app_storage[0].arn : null
      prefix               = var.app_storage_enabled ? local.app_storage_prefix : null
      storage_account_name = null
      storage_account_id   = null
      container_name       = null
    }
    health_policy = {
      kind                      = "http-readiness"
      telemetry_policy          = "honua-http"
      readiness_path            = "/healthz/ready"
      stable_job                = null
      canary_job                = null
      progressive_delivery      = false
      slot_based                = false
      current_slot              = null
      desired_slot              = null
      verification_header_name  = null
      verification_header_value = null
    }
    target = {
      kind           = "AwsLambda"
      backend_name   = "honua-gitops-aws-lambda"
      id             = "${aws_lambda_function.this.function_name}-${aws_lambda_alias.live.name}"
      name           = aws_lambda_function.this.function_name
      resource_id    = aws_lambda_alias.live.arn
      resource_group = null
      endpoint       = aws_apigatewayv2_api.this.api_endpoint
    }
    artifact = {
      kind    = "container-image"
      current = var.image
      desired = var.image
    }
    rollout = {
      current_revision     = aws_lambda_alias.live.function_version
      desired_revision     = aws_lambda_function.this.version
      progressive_delivery = false
      slot_based           = false
    }
    telemetry = {
      policy     = "honua-http"
      stable_job = null
      canary_job = null
    }
    capabilities = {
      object_storage = var.app_storage_enabled
      canary         = false
      slot           = false
    }
    marketplace = {
      schema_version  = "v1"
      eligible        = false
      turnkey_runtime = true
      bundle_profile  = "operator-only"
      target_family   = "aws-serverless"
      blocker_reason  = "Serverless runtime targets are excluded from marketplace-targeted bundles; prefer aws-ecs."
    }
  })
  sensitive = true
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
    object_storage = {
      enabled          = var.app_storage_enabled
      kind             = "s3"
      bucket_name      = var.app_storage_enabled ? aws_s3_bucket.app_storage[0].bucket : null
      bucket_arn       = var.app_storage_enabled ? aws_s3_bucket.app_storage[0].arn : null
      prefix           = var.app_storage_enabled ? local.app_storage_prefix : null
      runtime_role_arn = aws_iam_role.lambda.arn
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
      connection_encryption_master_key = {
        arn  = aws_secretsmanager_secret.connection_encryption_master_key.arn
        name = aws_secretsmanager_secret.connection_encryption_master_key.name
      }
      redis_connection = local.redis_enabled ? {
        arn  = aws_secretsmanager_secret.redis_connection[0].arn
        name = aws_secretsmanager_secret.redis_connection[0].name
      } : null
    }
  }
  sensitive = true
}
