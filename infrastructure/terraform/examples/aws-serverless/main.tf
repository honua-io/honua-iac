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
  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "aws-serverless"
      platform    = "aws-lambda"
      runtime     = "serverless"
      environment = module.honua.environment
      region      = module.honua.aws_region
    }
    endpoints = {
      public_base_url = module.honua.api_endpoint
      readiness_path  = "/healthz/ready"
      liveness_path   = "/healthz/live"
      admin_base_path = "/api/v1/admin"
      openapi_path    = "/openapi.json"
    }
    workload = {
      kind        = module.honua.control_plane_target_kind
      name        = module.honua.lambda_function_name
      resource_id = module.honua.lambda_function_arn
    }
    rollout = {
      backend_name       = module.honua.control_plane_backend_name
      target_id          = module.honua.control_plane_target_id
      target_name        = module.honua.control_plane_target_name
      target_resource_id = module.honua.control_plane_target_resource_id
      current_revision   = module.honua.control_plane_current_revision
      desired_revision   = module.honua.control_plane_desired_revision
      alias_name         = module.honua.lambda_alias_name
      alias_arn          = module.honua.lambda_alias_arn
      alias_invoke_arn   = module.honua.lambda_alias_invoke_arn
    }
    dependencies = {
      database = {
        provider = "aws"
        kind     = "rds-postgresql"
        managed  = var.existing_db_endpoint == "" && nonsensitive(var.existing_db_connection_string) == ""
      }
      cache = {
        provider = "aws"
        kind     = "elasticache-redis"
        enabled  = var.redis_enabled
        managed  = nonsensitive(var.redis_connection_string) == ""
      }
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "aws-lambda"
      capabilities = {
        deploy_plan = true
        mutation    = false
      }
    }
    tests = {
      base_url      = module.honua.api_endpoint
      readiness_url = "${module.honua.api_endpoint}/healthz/ready"
      admin_url     = "${module.honua.api_endpoint}/api/v1/admin"
    }
    lifecycle = {
      profile            = "ephemeral"
      reuses_shared_data = var.existing_db_endpoint != "" || nonsensitive(var.existing_db_connection_string) != ""
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy = module.honua.control_plane_telemetry_policy
    }
    grouping = {
      region = module.honua.aws_region
      tags   = var.tags
    }
    secret_store = {
      provider = "aws-secrets-manager"
    }
  }

  infrastructure_outputs = {
    environment = module.honua.environment
    region      = module.honua.aws_region
    endpoints = {
      public_base_url = module.honua.api_endpoint
    }
    workload = {
      function_name          = module.honua.lambda_function_name
      function_arn           = module.honua.lambda_function_arn
      alias_name             = module.honua.lambda_alias_name
      alias_arn              = module.honua.lambda_alias_arn
      alias_function_version = module.honua.lambda_alias_function_version
    }
  }

  infrastructure_secrets = {
    database_endpoint       = module.honua.db_endpoint
    redis_connection_string = module.honua.redis_connection_string
  }

  honua_integration_outputs = {
    control_plane = {
      target_kind        = module.honua.control_plane_target_kind
      backend_name       = module.honua.control_plane_backend_name
      target_id          = module.honua.control_plane_target_id
      target_name        = module.honua.control_plane_target_name
      target_resource_id = module.honua.control_plane_target_resource_id
      telemetry_policy   = module.honua.control_plane_telemetry_policy
      current_revision   = module.honua.control_plane_current_revision
      desired_revision   = module.honua.control_plane_desired_revision
    }
    contracts = {
      deployment = local.deployment_contract
      validation = local.validation_contract
      operations = local.operations_contract
    }
  }
}

output "honua_url" {
  value = module.honua.api_endpoint
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

output "infrastructure_outputs" {
  value = local.infrastructure_outputs
}

output "infrastructure_secrets" {
  value     = local.infrastructure_secrets
  sensitive = true
}

output "honua_integration_outputs" {
  value = local.honua_integration_outputs
}

output "deployment_contract" {
  value = local.deployment_contract
}

output "validation_contract" {
  value = local.validation_contract
}

output "operations_contract" {
  value = local.operations_contract
}
