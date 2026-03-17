provider "aws" {
  region = var.region
}

module "data" {
  source = "../../modules/aws-data"

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
  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "aws-data"
      platform    = "aws-data"
      runtime     = "data"
      environment = var.environment
      region      = var.region
    }
    endpoints = {
      public_base_url = null
      readiness_url   = null
      admin_url       = null
      protocol_url    = null
    }
    workload = {
      kind        = "AwsDataServices"
      name        = var.name_prefix
      resource_id = module.data.vpc_id
    }
    rollout = {
      backend_name       = null
      target_id          = null
      target_name        = null
      target_resource_id = null
      current_revision   = null
      desired_revision   = null
    }
    dependencies = {
      database = {
        kind       = "aws-rds-postgres"
        host       = module.data.db_endpoint
        secret_ref = module.data.db_connection_secret_arn
      }
      cache = {
        kind       = "aws-elasticache-redis"
        enabled    = var.redis_enabled
        host       = module.data.redis_primary_endpoint
        secret_ref = module.data.redis_connection_secret_arn
      }
      network = {
        kind               = "aws-vpc"
        id                 = module.data.vpc_id
        cidr               = module.data.vpc_cidr
        public_subnet_ids  = module.data.public_subnet_ids
        private_subnet_ids = module.data.private_subnet_ids
      }
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "aws-data"
      capabilities = {
        deploy_plan     = false
        mutation        = false
        scale_check     = false
        backup_drill    = true
        idempotency     = true
        protocol_checks = false
      }
    }
    tests = {
      base_url      = null
      readiness_url = null
      admin_url     = null
      protocol_url  = null
    }
    artifacts = {
      terraform_root = path.cwd
      vpc_id         = module.data.vpc_id
      region         = var.region
    }
    lifecycle = {
      reuse_data_stack = true
      destroy_mode     = "explicit"
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy      = null
      prometheus_job        = null
      prometheus_canary_job = null
      grafana_url           = null
    }
    secrets = {
      secret_store = {
        kind = "aws-secrets-manager"
        id   = null
      }
      admin_password_secret   = null
      db_connection_secret    = module.data.db_connection_secret_arn
      redis_connection_secret = module.data.redis_connection_secret_arn
    }
    grouping = {
      environment    = var.environment
      name_prefix    = var.name_prefix
      resource_group = null
      tags           = var.tags
    }
  }
}

output "deployment_contract" {
  description = "Stable deployment contract for validation and operator automation."
  value       = local.deployment_contract
  sensitive   = true
}

output "validation_contract" {
  description = "Stable validation contract for scenario orchestration."
  value       = local.validation_contract
}

output "operations_contract" {
  description = "Stable operations contract for day-2 metadata and secret references."
  value       = local.operations_contract
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
