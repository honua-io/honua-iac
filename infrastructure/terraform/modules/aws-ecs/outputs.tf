# --- Infrastructure outputs ---

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer."
  value       = aws_lb.this.dns_name
}

output "service_url" {
  description = "Convenience URL for the service."
  value       = local.use_https ? "https://${aws_lb.this.dns_name}" : "http://${aws_lb.this.dns_name}"
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "canary_enabled" {
  description = "Whether ALB canary resources are enabled."
  value       = var.canary_enabled
}

output "canary_ecs_service_name" {
  description = "Canary ECS service name when canary is enabled."
  value       = var.canary_enabled ? aws_ecs_service.canary[0].name : null
}

output "canary_target_group_arn" {
  description = "Canary target group ARN when canary is enabled."
  value       = var.canary_enabled ? aws_lb_target_group.canary[0].arn : null
}

output "canary_weight_percentage" {
  description = "Percentage of default ALB traffic routed to the canary target group."
  value       = var.canary_enabled ? var.canary_weight_percentage : 0
}

output "canary_verification_header_name" {
  description = "HTTP header name that routes requests directly to the canary service."
  value       = var.canary_enabled ? var.canary_header_name : null
}

output "canary_verification_header_value" {
  description = "HTTP header value that routes requests directly to the canary service."
  value       = var.canary_enabled ? var.canary_header_value : null
}

output "db_endpoint" {
  description = "RDS endpoint address."
  value       = local.db_endpoint
  sensitive   = true
}

output "db_connection_secret_arn" {
  description = "Secrets Manager ARN for the DB connection string."
  value       = aws_secretsmanager_secret.db_connection.arn
}

output "admin_password_secret_arn" {
  description = "Secrets Manager ARN for the admin password."
  value       = aws_secretsmanager_secret.admin_password.arn
}

output "connection_encryption_master_key_secret_arn" {
  description = "Secrets Manager ARN for the connection encryption master key."
  value       = aws_secretsmanager_secret.connection_encryption_master_key.arn
}

output "certificate_arn" {
  description = "ACM certificate ARN in use (if any)."
  value       = local.certificate_arn != "" ? local.certificate_arn : null
}

output "redis_connection_secret_arn" {
  description = "Secrets Manager ARN for the Redis connection string (if set)."
  value       = local.redis_connection != "" ? aws_secretsmanager_secret.redis_connection[0].arn : null
  sensitive   = true
}

output "redis_primary_endpoint" {
  description = "Redis primary endpoint address (if created)."
  value       = local.redis_create ? aws_elasticache_replication_group.redis[0].primary_endpoint_address : null
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
  description = "Recommended Honua control-plane deploy target kind for this environment."
  value       = "AwsEcs"
}

output "control_plane_backend_name" {
  description = "Recommended Honua control-plane backend identifier for this environment."
  value       = "honua-gitops-aws-ecs"
}

output "control_plane_contract_version" {
  description = "Schema version for the unified Honua control-plane contract."
  value       = "v2"
}

output "control_plane_target_id" {
  description = "Stable target id for Honua control-plane deploy operations."
  value       = "${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
}

output "control_plane_target_name" {
  description = "Primary workload name used by the Honua deploy target."
  value       = aws_ecs_service.this.name
}

output "control_plane_target_resource_id" {
  description = "Stable AWS resource identifier for the Honua deploy target."
  value       = aws_ecs_service.this.id
}

output "control_plane_target_resource_group" {
  description = "Logical grouping identifier for the deploy target when the cloud exposes one."
  value       = null
}

output "control_plane_telemetry_policy" {
  description = "Recommended deploy telemetry preset for the Honua control plane."
  value       = var.canary_enabled ? "aws-alb-canary" : "honua-http"
}

output "control_plane_telemetry_prometheus_job" {
  description = "Recommended Prometheus job label for stable Honua traffic when wiring control-plane rollback gates."
  value       = "honua"
}

output "control_plane_telemetry_prometheus_canary_job" {
  description = "Recommended Prometheus job label for canary Honua traffic when wiring control-plane rollback gates."
  value       = var.canary_enabled ? "honua-canary" : null
}

output "control_plane_current_revision" {
  description = "Current stable workload revision identifier."
  value       = aws_ecs_task_definition.this.arn
}

output "control_plane_desired_revision" {
  description = "Desired workload revision identifier for deploy orchestration."
  value       = local.canary_enabled ? aws_ecs_task_definition.canary[0].arn : aws_ecs_task_definition.this.arn
}

output "control_plane_current_image" {
  description = "Current stable artifact reference used by the deploy target."
  value       = var.image
}

output "control_plane_desired_image" {
  description = "Desired artifact reference used by the deploy target."
  value       = local.canary_enabled ? local.effective_canary_image : var.image
}

output "marketplace_profile" {
  description = "Machine-readable marketplace deployment support profile."
  value = {
    schema_version  = "v1"
    eligible        = true
    turnkey_runtime = true
    bundle_profile  = "marketplace-turnkey"
    target_family   = "aws-container-runtime"
    blocker_reason  = null
  }
}

output "control_plane_contract" {
  description = "Unified control-plane contract for deploy automation and marketplace packaging."
  value = nonsensitive({
    schema_version = "v2"
    backend_name   = "honua-gitops-aws-ecs"
    target_kind    = "AwsEcs"
    target_id      = "${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
    target_name    = aws_ecs_service.this.name
    resource_id    = aws_ecs_service.this.id
    resource_group = null
    endpoint       = local.use_https ? "https://${aws_lb.this.dns_name}" : "http://${aws_lb.this.dns_name}"
    artifact_reference = {
      kind    = "container-image"
      current = var.image
      desired = local.canary_enabled ? local.effective_canary_image : var.image
    }
    current_revision = aws_ecs_task_definition.this.arn
    desired_revision = local.canary_enabled ? aws_ecs_task_definition.canary[0].arn : aws_ecs_task_definition.this.arn
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
        id             = aws_secretsmanager_secret.db_connection.arn
        name           = aws_secretsmanager_secret.db_connection.name
        versionless_id = null
      }
      redis_connection = local.redis_connection != "" ? {
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
      telemetry_policy          = var.canary_enabled ? "aws-alb-canary" : "honua-http"
      readiness_path            = var.health_check_path
      stable_job                = "honua"
      canary_job                = var.canary_enabled ? "honua-canary" : null
      progressive_delivery      = var.canary_enabled
      slot_based                = false
      current_slot              = null
      desired_slot              = null
      verification_header_name  = var.canary_enabled ? var.canary_header_name : null
      verification_header_value = var.canary_enabled ? var.canary_header_value : null
    }
    target = {
      kind           = "AwsEcs"
      backend_name   = "honua-gitops-aws-ecs"
      id             = "${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
      name           = aws_ecs_service.this.name
      resource_id    = aws_ecs_service.this.id
      resource_group = null
      endpoint       = local.use_https ? "https://${aws_lb.this.dns_name}" : "http://${aws_lb.this.dns_name}"
    }
    artifact = {
      kind    = "container-image"
      current = var.image
      desired = local.canary_enabled ? local.effective_canary_image : var.image
    }
    rollout = {
      current_revision     = aws_ecs_task_definition.this.arn
      desired_revision     = local.canary_enabled ? aws_ecs_task_definition.canary[0].arn : aws_ecs_task_definition.this.arn
      progressive_delivery = var.canary_enabled
      slot_based           = false
    }
    telemetry = {
      policy     = var.canary_enabled ? "aws-alb-canary" : "honua-http"
      stable_job = "honua"
      canary_job = var.canary_enabled ? "honua-canary" : null
    }
    capabilities = {
      object_storage = var.app_storage_enabled
      canary         = var.canary_enabled
      slot           = false
    }
    marketplace = {
      schema_version  = "v1"
      eligible        = true
      turnkey_runtime = true
      bundle_profile  = "marketplace-turnkey"
      target_family   = "aws-container-runtime"
      blocker_reason  = null
    }
  })
  sensitive = true
}

output "operations_metadata" {
  description = "Structured operational metadata for workload, backup/restore, and secret rotation runbooks."
  value = {
    workload = {
      cluster_name               = aws_ecs_cluster.this.name
      cluster_arn                = aws_ecs_cluster.this.arn
      service_name               = aws_ecs_service.this.name
      autoscaling_resource_id    = aws_appautoscaling_target.ecs.resource_id
      task_definition_arn        = aws_ecs_task_definition.this.arn
      stable_log_group_name      = aws_cloudwatch_log_group.this.name
      canary_service_name        = var.canary_enabled ? aws_ecs_service.canary[0].name : null
      canary_target_group_arn    = var.canary_enabled ? aws_lb_target_group.canary[0].arn : null
      canary_task_definition_arn = var.canary_enabled ? aws_ecs_task_definition.canary[0].arn : null
      alb_dns_name               = aws_lb.this.dns_name
      certificate_arn            = local.certificate_arn != "" ? local.certificate_arn : null
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
        arn  = aws_secretsmanager_secret.db_connection.arn
        name = aws_secretsmanager_secret.db_connection.name
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
      runtime_role_arn = aws_iam_role.task.arn
    }
    secrets = {
      db_connection = {
        arn  = aws_secretsmanager_secret.db_connection.arn
        name = aws_secretsmanager_secret.db_connection.name
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
    encryption = {
      kms_key_arn = local.kms_key_arn
    }
  }
  sensitive = true
}
