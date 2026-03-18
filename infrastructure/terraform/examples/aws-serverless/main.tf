provider "aws" {
  region = var.region
}

module "honua" {
  source = "../../modules/aws-serverless"

  environment                     = var.environment
  name_prefix                     = var.name_prefix
  existing_vpc_id                 = var.existing_vpc_id
  existing_vpc_cidr               = var.existing_vpc_cidr
  existing_public_subnet_ids      = var.existing_public_subnet_ids
  existing_private_subnet_ids     = var.existing_private_subnet_ids
  image                           = var.honua_image_uri
  lambda_architectures            = var.lambda_architectures
  lambda_alias_name               = var.lambda_alias_name
  lambda_alias_version            = var.lambda_alias_version
  admin_password                  = var.honua_admin_password
  db_password                     = var.db_password
  existing_db_endpoint            = var.existing_db_endpoint
  existing_db_connection_string   = var.existing_db_connection_string
  db_publicly_accessible          = var.db_publicly_accessible
  db_additional_ingress_cidrs     = var.db_additional_ingress_cidrs
  enable_postgis                  = var.enable_postgis
  postgis_readiness_max_attempts  = var.postgis_readiness_max_attempts
  postgis_readiness_sleep_seconds = var.postgis_readiness_sleep_seconds
  redis_enabled                   = var.redis_enabled
  redis_connection_string         = var.redis_connection_string
  redis_connection_cidrs          = var.redis_connection_cidrs
  skip_migrations                 = var.skip_migrations
  tags                            = var.tags

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
  }
}

locals {
  honua_url     = module.honua.api_endpoint
  db_reused     = var.existing_db_endpoint != "" && var.existing_db_connection_string != ""
  cache_enabled = var.redis_enabled || var.redis_connection_string != ""
  cache_reused  = var.redis_connection_string != ""

  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "aws-serverless"
      platform    = "aws-serverless"
      runtime     = "serverless"
      environment = var.environment
      region      = var.region
    }
    endpoints = {
      public_base_url = local.honua_url
      readiness_url   = "${local.honua_url}/healthz/ready"
      admin_url       = "${local.honua_url}/api/v1/admin"
      protocol_url    = "${local.honua_url}/v1"
    }
    workload = {
      kind        = module.honua.control_plane_target_kind
      name        = module.honua.lambda_function_name
      resource_id = module.honua.lambda_function_arn
      alias_name  = module.honua.lambda_alias_name
    }
    rollout = {
      backend_name       = module.honua.control_plane_backend_name
      target_id          = module.honua.control_plane_target_id
      target_name        = module.honua.control_plane_target_name
      target_resource_id = module.honua.control_plane_target_resource_id
      current_revision   = module.honua.control_plane_current_revision
      desired_revision   = module.honua.control_plane_desired_revision
      current_image      = var.honua_image_uri
      desired_image      = var.honua_image_uri
    }
    dependencies = {
      database = {
        kind       = "aws-rds-postgres"
        host       = module.honua.db_endpoint
        reused     = local.db_reused
        secret_ref = module.honua.db_connection_secret_arn
      }
      cache = {
        kind       = "aws-elasticache-redis"
        enabled    = local.cache_enabled
        reused     = local.cache_reused
        host       = null
        secret_ref = module.honua.redis_connection_secret_arn
      }
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "aws-serverless"
      capabilities = {
        deploy_plan     = true
        mutation        = false
        scale_check     = false
        backup_drill    = true
        idempotency     = true
        protocol_checks = true
      }
    }
    tests = {
      base_url      = local.honua_url
      readiness_url = "${local.honua_url}/healthz/ready"
      admin_url     = "${local.honua_url}/api/v1/admin"
      protocol_url  = "${local.honua_url}/v1"
    }
    artifacts = {
      terraform_root = path.cwd
      workload_name  = module.honua.lambda_function_name
      alias_name     = module.honua.lambda_alias_name
      region         = var.region
    }
    lifecycle = {
      reuse_data_stack = local.db_reused
      destroy_mode     = "explicit"
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy      = module.honua.control_plane_telemetry_policy
      prometheus_job        = null
      prometheus_canary_job = null
      grafana_url           = null
    }
    runbooks = module.honua.operations_metadata
    secrets = {
      secret_store = {
        kind = "aws-secrets-manager"
        id   = null
      }
      admin_password_secret   = module.honua.admin_password_secret_arn
      db_connection_secret    = module.honua.db_connection_secret_arn
      redis_connection_secret = module.honua.redis_connection_secret_arn
    }
    grouping = {
      environment    = var.environment
      name_prefix    = var.name_prefix
      resource_group = null
      tags           = var.tags
    }
  }
}

output "honua_url" {
  value = local.honua_url
}

output "deployment_contract" {
  description = "Stable deployment contract for validation and operator automation."
  value       = local.deployment_contract
  sensitive   = true
}

output "validation_contract" {
  description = "Stable validation contract for scenario orchestration."
  value       = local.validation_contract
  sensitive   = true
}

output "operations_contract" {
  description = "Stable operations contract for day-2 metadata and secret references."
  value       = local.operations_contract
  sensitive   = true
}

output "operations_metadata" {
  description = "Structured operational metadata for backup/restore and secret rotation runbooks."
  value       = module.honua.operations_metadata
  sensitive   = true
}

output "environment" {
  value = module.honua.environment
}

output "aws_region" {
  value = module.honua.aws_region
}

output "lambda_function_name" {
  value = module.honua.lambda_function_name
}

output "lambda_function_arn" {
  value = module.honua.lambda_function_arn
}

output "lambda_function_version" {
  value = module.honua.lambda_function_version
}

output "lambda_alias_name" {
  value = module.honua.lambda_alias_name
}

output "lambda_alias_arn" {
  value = module.honua.lambda_alias_arn
}

output "lambda_alias_invoke_arn" {
  value = module.honua.lambda_alias_invoke_arn
}

output "lambda_alias_function_version" {
  value = module.honua.lambda_alias_function_version
}

output "control_plane_target_kind" {
  value = module.honua.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.honua.control_plane_backend_name
}

output "control_plane_target_id" {
  value = module.honua.control_plane_target_id
}

output "control_plane_target_name" {
  value = module.honua.control_plane_target_name
}

output "control_plane_target_resource_id" {
  value = module.honua.control_plane_target_resource_id
}

output "control_plane_telemetry_policy" {
  value = module.honua.control_plane_telemetry_policy
}

output "control_plane_current_revision" {
  value = module.honua.control_plane_current_revision
}

output "control_plane_desired_revision" {
  value = module.honua.control_plane_desired_revision
}

output "db_endpoint" {
  value     = module.honua.db_endpoint
  sensitive = true
}

output "redis_connection_string" {
  value     = module.honua.redis_connection_string
  sensitive = true
}
