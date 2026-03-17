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
  honua_url     = module.honua.service_url
  db_reused     = var.existing_db_endpoint != "" && var.existing_db_connection_string != ""
  cache_enabled = var.redis_enabled || var.redis_connection_string != ""
  cache_reused  = var.redis_connection_string != ""

  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "aws-ecs"
      platform    = "aws-ecs"
      runtime     = "container"
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
      kind         = module.honua.control_plane_target_kind
      name         = module.honua.ecs_service_name
      resource_id  = null
      cluster_name = module.honua.ecs_cluster_name
    }
    rollout = {
      backend_name                     = module.honua.control_plane_backend_name
      target_id                        = module.honua.ecs_service_name
      target_name                      = module.honua.ecs_service_name
      target_resource_id               = null
      current_revision                 = null
      desired_revision                 = null
      current_image                    = var.honua_image
      desired_image                    = var.honua_image
      canary_enabled                   = module.honua.canary_enabled
      canary_service_name              = module.honua.canary_ecs_service_name
      canary_verification_header_name  = module.honua.canary_verification_header_name
      canary_verification_header_value = module.honua.canary_verification_header_value
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
        host       = module.honua.redis_primary_endpoint
        secret_ref = module.honua.redis_connection_secret_arn
      }
      ingress = {
        kind            = "aws-alb"
        certificate_arn = module.honua.certificate_arn
      }
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "aws-ecs"
      capabilities = {
        deploy_plan     = var.canary_enabled
        mutation        = var.canary_enabled
        scale_check     = true
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
      workload_name  = module.honua.ecs_service_name
      cluster_name   = module.honua.ecs_cluster_name
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
      prometheus_job        = module.honua.control_plane_telemetry_prometheus_job
      prometheus_canary_job = module.honua.control_plane_telemetry_prometheus_canary_job
      grafana_url           = null
    }
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
}

output "operations_contract" {
  description = "Stable operations contract for day-2 metadata and secret references."
  value       = local.operations_contract
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
