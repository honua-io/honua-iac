// Validation stack wrapper around the canonical customer stack.

module "stack" {
  source = "../../customer/aws-data"

  region                          = var.region
  environment                     = var.environment
  name_prefix                     = var.name_prefix
  db_password                     = var.db_password
  db_publicly_accessible          = var.db_publicly_accessible
  db_additional_ingress_cidrs     = var.db_additional_ingress_cidrs
  enable_postgis                  = var.enable_postgis
  postgis_readiness_max_attempts  = var.postgis_readiness_max_attempts
  postgis_readiness_sleep_seconds = var.postgis_readiness_sleep_seconds
  redis_enabled                   = var.redis_enabled
  redis_node_type                 = var.redis_node_type
  redis_num_cache_clusters        = var.redis_num_cache_clusters
  tags                            = var.tags
}

output "vpc_id" {
  value = module.stack.vpc_id
}

output "vpc_cidr" {
  value = module.stack.vpc_cidr
}

output "public_subnet_ids" {
  value = module.stack.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.stack.private_subnet_ids
}

output "db_endpoint" {
  value = module.stack.db_endpoint
}

output "db_connection_string" {
  value = module.stack.db_connection_string
}

output "redis_connection_string" {
  value = module.stack.redis_connection_string
}

output "infrastructure_outputs" {
  value = module.stack.infrastructure_outputs
}

output "infrastructure_secrets" {
  value = module.stack.infrastructure_secrets
}
