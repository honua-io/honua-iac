provider "aws" {
  region = var.region
}

module "honua" {
  source = "../../modules/aws-ecs"

  environment                     = var.environment
  name_prefix                     = var.name_prefix
  existing_vpc_id                 = var.existing_vpc_id
  existing_vpc_cidr               = var.existing_vpc_cidr
  existing_public_subnet_ids      = var.existing_public_subnet_ids
  existing_private_subnet_ids     = var.existing_private_subnet_ids
  image                           = var.honua_image
  task_cpu_architecture           = var.task_cpu_architecture
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
  desired_count                   = var.desired_count
  canary_enabled                  = var.canary_enabled
  canary_image                    = var.canary_image
  canary_desired_count            = var.canary_desired_count
  canary_weight_percentage        = var.canary_weight_percentage
  alb_deletion_protection         = var.alb_deletion_protection
  alb_access_logs_enabled         = var.alb_access_logs_enabled
  alb_access_logs_force_destroy   = var.alb_access_logs_force_destroy
  alb_certificate_arn             = var.alb_certificate_arn
  allow_http_ingress_cidrs        = var.allow_http_ingress_cidrs
  waf_web_acl_arn                 = var.waf_web_acl_arn
  tags                            = var.tags

  additional_env = {
    HONUA_SERVE_ADMIN_UI    = "true"
    HONUA_ADMIN_UI          = "true"
    HostValidation__Enabled = "false"
  }
}

locals {
  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "aws-ecs"
      platform    = "aws-ecs"
      runtime     = "containers"
      environment = var.environment
      region      = var.region
    }
    endpoints = {
      public_base_url = module.honua.service_url
      readiness_path  = "/healthz/ready"
      liveness_path   = "/healthz/live"
      admin_base_path = "/api/v1/admin"
      openapi_path    = "/openapi.json"
    }
    workload = {
      kind         = module.honua.control_plane_target_kind
      name         = module.honua.ecs_service_name
      cluster_name = module.honua.ecs_cluster_name
      canary_name  = module.honua.canary_ecs_service_name
    }
    rollout = {
      backend_name                    = module.honua.control_plane_backend_name
      target_id                       = "${var.environment}-${module.honua.ecs_service_name}"
      target_name                     = module.honua.ecs_service_name
      telemetry_policy                = module.honua.control_plane_telemetry_policy
      telemetry_prometheus_job        = module.honua.control_plane_telemetry_prometheus_job
      telemetry_prometheus_canary_job = module.honua.control_plane_telemetry_prometheus_canary_job
      canary_enabled                  = module.honua.canary_enabled
      canary_weight_percentage        = module.honua.canary_enabled ? var.canary_weight_percentage : 0
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
      network = {
        provider = "aws"
        managed  = var.existing_vpc_id == ""
      }
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "aws-ecs"
      capabilities = {
        deploy_plan = true
        mutation    = false
      }
    }
    tests = {
      base_url             = module.honua.service_url
      readiness_url        = "${module.honua.service_url}/healthz/ready"
      admin_url            = "${module.honua.service_url}/api/v1/admin"
      expected_environment = var.environment
      extra_header_name    = module.honua.canary_verification_header_name
      extra_header_value   = module.honua.canary_verification_header_value
    }
    lifecycle = {
      profile            = "ephemeral"
      reuses_shared_data = var.existing_db_endpoint != "" || nonsensitive(var.existing_db_connection_string) != ""
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy          = module.honua.control_plane_telemetry_policy
      prometheus_job            = module.honua.control_plane_telemetry_prometheus_job
      prometheus_canary_job     = module.honua.control_plane_telemetry_prometheus_canary_job
      canary_verification_name  = module.honua.canary_verification_header_name
      canary_verification_value = module.honua.canary_verification_header_value
    }
    grouping = {
      region = var.region
      tags   = var.tags
    }
    secret_store = {
      provider = "aws-secrets-manager"
    }
  }
}

output "honua_url" {
  value = module.honua.service_url
}

output "ecs_cluster_name" {
  value = module.honua.ecs_cluster_name
}

output "ecs_service_name" {
  value = module.honua.ecs_service_name
}

output "canary_enabled" {
  value = module.honua.canary_enabled
}

output "canary_ecs_service_name" {
  value = module.honua.canary_ecs_service_name
}

output "canary_verification_header_name" {
  value = module.honua.canary_verification_header_name
}

output "canary_verification_header_value" {
  value = module.honua.canary_verification_header_value
}

output "control_plane_target_kind" {
  value = module.honua.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.honua.control_plane_backend_name
}

output "control_plane_telemetry_policy" {
  value = module.honua.control_plane_telemetry_policy
}

output "control_plane_telemetry_prometheus_job" {
  value = module.honua.control_plane_telemetry_prometheus_job
}

output "control_plane_telemetry_prometheus_canary_job" {
  value = module.honua.control_plane_telemetry_prometheus_canary_job
}

output "db_endpoint" {
  value     = module.honua.db_endpoint
  sensitive = true
}

output "redis_primary_endpoint" {
  value     = module.honua.redis_primary_endpoint
  sensitive = true
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
