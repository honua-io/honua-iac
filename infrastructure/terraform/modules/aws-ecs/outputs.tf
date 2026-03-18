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

# --- Honua control-plane outputs ---

output "control_plane_target_kind" {
  description = "Recommended Honua control-plane deploy target kind for this environment."
  value       = "AwsEcs"
}

output "control_plane_backend_name" {
  description = "Recommended Honua control-plane backend identifier for this environment."
  value       = "honua-gitops-aws-ecs"
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
    secrets = {
      db_connection = {
        arn  = aws_secretsmanager_secret.db_connection.arn
        name = aws_secretsmanager_secret.db_connection.name
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
    encryption = {
      kms_key_arn = local.kms_key_arn
    }
  }
  sensitive = true
}
