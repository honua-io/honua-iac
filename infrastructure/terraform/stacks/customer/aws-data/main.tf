provider "aws" {
  region = var.region
}

module "data" {
  source = "../../../components/data/aws-postgres-redis"

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

locals {
  infrastructure_outputs = {
    environment = var.environment
    region      = var.region
    network = {
      vpc_id             = module.data.vpc_id
      vpc_cidr           = module.data.vpc_cidr
      public_subnet_ids  = module.data.public_subnet_ids
      private_subnet_ids = module.data.private_subnet_ids
    }
  }

  infrastructure_secrets = {
    database_endpoint       = module.data.db_endpoint
    database_connection     = module.data.db_connection_string
    redis_connection_string = module.data.redis_connection_string
  }
}

output "vpc_id" {
  value = module.data.vpc_id
}

output "vpc_cidr" {
  value = module.data.vpc_cidr
}

output "public_subnet_ids" {
  value = module.data.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.data.private_subnet_ids
}

output "db_endpoint" {
  value     = module.data.db_endpoint
  sensitive = true
}

output "db_connection_string" {
  value     = module.data.db_connection_string
  sensitive = true
}

output "redis_connection_string" {
  value     = module.data.redis_connection_string
  sensitive = true
}

output "infrastructure_outputs" {
  value = local.infrastructure_outputs
}

output "infrastructure_secrets" {
  value     = local.infrastructure_secrets
  sensitive = true
}
