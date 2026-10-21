# Non-secret facts for the customer-facing operator-contract producer. Derive
# routing and ownership from the same resources/locals used by the runtime.
output "operator_contract_facts" {
  description = "Non-secret applied Lambda dependency facts for the operator contract; not a verified installation receipt."
  value = {
    workload_identity = aws_lambda_function.this.role
    resource_group    = local.name
    tags              = local.tags
    log_group         = aws_cloudwatch_log_group.lambda.name
    metrics_namespace = "Honua/${local.name}"
    # Declassify only the presence/ownership booleans, never connection values.
    database_managed  = !nonsensitive(local.db_use_existing)
    database_kind     = nonsensitive(local.db_use_existing) ? "postgres" : "aws-rds-postgres"
    database_endpoint = nonsensitive(local.rds_proxy_enabled ? aws_db_proxy.this[0].endpoint : local.db_endpoint)
    cache_kind        = nonsensitive(local.redis_create) ? "aws-elasticache-redis" : "redis"
    object_storage = {
      kind    = local.file_storage_shared ? "aws-s3" : null
      enabled = local.file_storage_shared
      bucket  = local.file_storage_shared ? var.file_storage_aws_s3_bucket_name : null
      prefix  = local.file_storage_shared ? var.file_storage_aws_s3_key_prefix : null
    }
  }
}
