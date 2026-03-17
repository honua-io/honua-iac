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
