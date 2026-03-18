# --- Infrastructure outputs ---

output "vpc_id" {
  description = "VPC ID for the data stack."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "CIDR block for the data stack VPC."
  value       = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs for the data stack VPC."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "Private subnet IDs for the data stack VPC."
  value       = module.vpc.private_subnets
}

output "db_endpoint" {
  description = "RDS endpoint address."
  value       = local.db_endpoint
  sensitive   = true
}

output "db_connection_string" {
  description = "PostgreSQL connection string."
  value       = local.db_connection_string
  sensitive   = true
}

output "db_connection_secret_arn" {
  description = "Secrets Manager ARN for the DB connection string."
  value       = aws_secretsmanager_secret.db_connection.arn
}

output "redis_connection_string" {
  description = "Redis connection string (empty if redis_enabled=false)."
  value       = local.redis_connection
  sensitive   = true
}

output "redis_connection_secret_arn" {
  description = "Secrets Manager ARN for the Redis connection string (null if redis_enabled=false)."
  value       = var.redis_enabled ? aws_secretsmanager_secret.redis_connection[0].arn : null
  sensitive   = true
}

output "redis_primary_endpoint" {
  description = "Redis primary endpoint address (null if redis_enabled=false)."
  value       = var.redis_enabled ? aws_elasticache_replication_group.redis[0].primary_endpoint_address : null
  sensitive   = true
}

output "operations_metadata" {
  description = "Structured operational metadata for backup/restore and secret rotation runbooks."
  value = {
    database = {
      engine                = "postgres"
      identifier            = "${local.name}-postgres"
      endpoint              = local.db_endpoint
      database_name         = var.db_name
      username              = var.db_username
      port                  = 5432
      backup_retention_days = var.environment == "prod" ? 7 : 3
      multi_az              = var.db_multi_az
      publicly_accessible   = var.db_publicly_accessible
      secret_ref = {
        arn  = aws_secretsmanager_secret.db_connection.arn
        name = aws_secretsmanager_secret.db_connection.name
      }
      postgis = {
        enabled                 = var.enable_postgis
        provisioner             = "postgresql_extension"
        readiness_max_attempts  = var.postgis_readiness_max_attempts
        readiness_sleep_seconds = var.postgis_readiness_sleep_seconds
        extensions              = ["postgis", "postgis_raster"]
      }
    }
    cache = {
      enabled            = var.redis_enabled
      identifier         = var.redis_enabled ? aws_elasticache_replication_group.redis[0].replication_group_id : null
      arn                = var.redis_enabled ? aws_elasticache_replication_group.redis[0].arn : null
      endpoint           = var.redis_enabled ? aws_elasticache_replication_group.redis[0].primary_endpoint_address : null
      port               = var.redis_port
      transit_encryption = true
      at_rest_encryption = true
      secret_ref = var.redis_enabled ? {
        arn  = aws_secretsmanager_secret.redis_connection[0].arn
        name = aws_secretsmanager_secret.redis_connection[0].name
      } : null
    }
    network = {
      vpc_id             = module.vpc.vpc_id
      vpc_cidr           = module.vpc.vpc_cidr_block
      public_subnet_ids  = module.vpc.public_subnets
      private_subnet_ids = module.vpc.private_subnets
    }
  }
  sensitive = true
}
