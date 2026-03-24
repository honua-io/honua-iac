provider "aws" {
  region = var.region
}

module "honua" {
  source = "../../modules/aws-ecs"

  environment                            = var.environment
  name_prefix                            = var.name_prefix
  existing_vpc_id                        = local.install_network_id
  existing_vpc_cidr                      = local.install_network_cidr
  existing_public_subnet_ids             = local.install_network_public_subnet_ids
  existing_private_subnet_ids            = local.install_network_private_subnet_ids
  image                                  = local.install_artifact_image
  container_port                         = var.container_port
  container_cpu                          = var.container_cpu
  container_memory                       = var.container_memory
  task_cpu_architecture                  = var.task_cpu_architecture
  admin_password                         = var.honua_admin_password
  connection_encryption_master_key       = var.connection_encryption_master_key
  db_password                            = var.db_password
  existing_db_endpoint                   = local.install_database_host
  existing_db_connection_string          = var.existing_db_connection_string
  existing_db_cidrs                      = var.existing_db_cidrs
  db_instance_class                      = local.install_database_compute_sku
  db_allocated_storage                   = local.install_database_storage_gb
  db_max_allocated_storage               = local.install_database_max_storage_gb
  db_maintenance_window                  = var.db_maintenance_window
  db_publicly_accessible                 = local.install_database_public_access
  db_additional_ingress_cidrs            = var.db_additional_ingress_cidrs
  enable_postgis                         = local.install_database_postgis_enabled
  postgis_readiness_max_attempts         = local.install_database_readiness_max_attempts
  postgis_readiness_sleep_seconds        = local.install_database_readiness_sleep_seconds
  redis_enabled                          = local.install_redis_enabled
  redis_connection_string                = var.redis_connection_string
  redis_connection_cidrs                 = var.redis_connection_cidrs
  desired_count                          = var.desired_count
  min_capacity                           = var.min_capacity
  max_capacity                           = var.max_capacity
  autoscaling_cpu_target_value           = var.autoscaling_cpu_target_value
  autoscaling_scale_in_cooldown_seconds  = var.autoscaling_scale_in_cooldown_seconds
  autoscaling_scale_out_cooldown_seconds = var.autoscaling_scale_out_cooldown_seconds
  canary_enabled                         = var.canary_enabled
  canary_image                           = var.canary_image
  canary_desired_count                   = var.canary_desired_count
  canary_weight_percentage               = var.canary_weight_percentage
  app_storage_enabled                    = local.install_storage_enabled
  app_storage_bucket_name                = local.install_storage_name
  app_storage_prefix                     = local.install_storage_prefix
  app_storage_force_destroy              = local.install_storage_force_destroy
  alb_deletion_protection                = var.alb_deletion_protection
  alb_access_logs_enabled                = var.alb_access_logs_enabled
  alb_access_logs_force_destroy          = var.alb_access_logs_force_destroy
  alb_certificate_arn                    = var.alb_certificate_arn
  allow_http_ingress_cidrs               = local.install_network_allow_http_ingress_cidrs
  allow_https_ingress_cidrs              = local.install_network_allow_https_ingress_cidrs
  waf_web_acl_arn                        = var.waf_web_acl_arn
  tags                                   = var.tags

  additional_env = {
    HONUA_SERVE_ADMIN_UI    = "true"
    HONUA_ADMIN_UI          = "true"
    HostValidation__Enabled = "false"
  }
}

locals {
  install_artifact_image                    = try(var.install.artifact.image, null) != null ? trimspace(var.install.artifact.image) : (var.honua_image != null ? trimspace(var.honua_image) : null)
  install_database_host                     = try(var.install.database.host, null) != null ? trimspace(var.install.database.host) : var.existing_db_endpoint
  install_database_compute_sku              = try(var.install.database.compute_sku, null) != null ? var.install.database.compute_sku : var.db_instance_class
  install_database_storage_gb               = try(var.install.database.storage_gb, null) != null ? var.install.database.storage_gb : var.db_allocated_storage
  install_database_max_storage_gb           = try(var.install.database.max_storage_gb, null) != null ? var.install.database.max_storage_gb : var.db_max_allocated_storage
  install_database_public_access            = try(var.install.database.public_access, null) != null ? var.install.database.public_access : var.db_publicly_accessible
  install_database_postgis_enabled          = try(var.install.database.postgis_enabled, null) != null ? var.install.database.postgis_enabled : var.enable_postgis
  install_database_readiness_max_attempts   = try(var.install.database.readiness_max_attempts, null) != null ? var.install.database.readiness_max_attempts : var.postgis_readiness_max_attempts
  install_database_readiness_sleep_seconds  = try(var.install.database.readiness_sleep_seconds, null) != null ? var.install.database.readiness_sleep_seconds : var.postgis_readiness_sleep_seconds
  install_redis_enabled                     = trimspace(var.redis_connection_string) != "" ? false : var.redis_enabled
  install_network_id                        = try(var.install.network.id, null) != null ? trimspace(var.install.network.id) : var.existing_vpc_id
  install_network_cidr                      = try(var.install.network.cidr, null) != null ? trimspace(var.install.network.cidr) : var.existing_vpc_cidr
  install_network_public_subnet_ids         = try(var.install.network.public_subnet_ids, null) != null ? var.install.network.public_subnet_ids : var.existing_public_subnet_ids
  install_network_private_subnet_ids        = try(var.install.network.private_subnet_ids, null) != null ? var.install.network.private_subnet_ids : var.existing_private_subnet_ids
  install_network_public_ingress_cidrs      = try(var.install.network.public_ingress_cidrs, null)
  install_network_allow_http_ingress_cidrs  = try(var.install.network.http_ingress_cidrs, null) != null ? var.install.network.http_ingress_cidrs : (local.install_network_public_ingress_cidrs != null ? local.install_network_public_ingress_cidrs : var.allow_http_ingress_cidrs)
  install_network_allow_https_ingress_cidrs = try(var.install.network.https_ingress_cidrs, null) != null ? var.install.network.https_ingress_cidrs : (local.install_network_public_ingress_cidrs != null ? local.install_network_public_ingress_cidrs : [])
  install_storage_enabled                   = try(var.install.storage.enabled, null) != null ? var.install.storage.enabled : var.app_storage_enabled
  install_storage_name                      = try(var.install.storage.name, null) != null ? trimspace(var.install.storage.name) : var.app_storage_bucket_name
  install_storage_prefix                    = try(var.install.storage.prefix, null) != null ? trimspace(var.install.storage.prefix) : var.app_storage_prefix
  install_storage_force_destroy             = try(var.install.storage.force_destroy, null) != null ? var.install.storage.force_destroy : var.app_storage_force_destroy
  honua_url                                 = module.honua.service_url
  db_reused                                 = local.install_database_host != "" && var.existing_db_connection_string != ""
  cache_enabled                             = local.install_redis_enabled || var.redis_connection_string != ""
  cache_reused                              = var.redis_connection_string != ""

  install_contract = {
    schema_version = "v1"
    artifact = {
      image = local.install_artifact_image
      registry = {
        server      = null
        auth_mode   = null
        resource_id = null
      }
    }
    database = {
      host                    = local.install_database_host != "" ? local.install_database_host : null
      connection_reused       = nonsensitive(var.existing_db_connection_string != "")
      compute_sku             = local.install_database_compute_sku
      storage_gb              = local.install_database_storage_gb
      max_storage_gb          = local.install_database_max_storage_gb
      public_access           = local.install_database_public_access
      postgis_enabled         = local.install_database_postgis_enabled
      readiness_max_attempts  = local.install_database_readiness_max_attempts
      readiness_sleep_seconds = local.install_database_readiness_sleep_seconds
    }
    network = {
      id                   = local.install_network_id != "" ? local.install_network_id : null
      cidr                 = local.install_network_cidr != "" ? local.install_network_cidr : null
      public_subnet_ids    = local.install_network_public_subnet_ids
      private_subnet_ids   = local.install_network_private_subnet_ids
      public_ingress_cidrs = local.install_network_public_ingress_cidrs
      http_ingress_cidrs   = local.install_network_allow_http_ingress_cidrs
      https_ingress_cidrs  = local.install_network_allow_https_ingress_cidrs
      firewall_start_ip    = null
      firewall_end_ip      = null
    }
    storage = {
      enabled        = local.install_storage_enabled
      name           = local.install_storage_name != "" ? local.install_storage_name : null
      container_name = null
      prefix         = local.install_storage_enabled ? local.install_storage_prefix : null
      force_destroy  = local.install_storage_force_destroy
    }
  }

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
      resource_id  = module.honua.control_plane_target_resource_id
      cluster_name = module.honua.ecs_cluster_name
    }
    rollout = {
      backend_name                     = module.honua.control_plane_backend_name
      target_id                        = module.honua.control_plane_target_id
      target_name                      = module.honua.control_plane_target_name
      target_resource_id               = module.honua.control_plane_target_resource_id
      current_revision                 = module.honua.control_plane_current_revision
      desired_revision                 = module.honua.control_plane_desired_revision
      current_image                    = module.honua.control_plane_current_image
      desired_image                    = module.honua.control_plane_desired_image
      canary_enabled                   = module.honua.canary_enabled
      canary_service_name              = module.honua.canary_ecs_service_name
      canary_verification_header_name  = module.honua.canary_verification_header_name
      canary_verification_header_value = module.honua.canary_verification_header_value
    }
    deploy = module.honua.control_plane_contract
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
      object_storage = {
        kind    = "aws-s3"
        enabled = module.honua.app_storage_enabled
        bucket  = module.honua.app_storage_bucket_name
        prefix  = module.honua.app_storage_prefix
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
        object_storage  = module.honua.app_storage_enabled
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
    runbooks = module.honua.operations_metadata
    secrets = {
      secret_store = {
        kind = "aws-secrets-manager"
        id   = null
      }
      admin_password_secret                   = module.honua.admin_password_secret_arn
      connection_encryption_master_key_secret = module.honua.connection_encryption_master_key_secret_arn
      db_connection_secret                    = module.honua.db_connection_secret_arn
      redis_connection_secret                 = module.honua.redis_connection_secret_arn
    }
    grouping = {
      environment    = var.environment
      name_prefix    = var.name_prefix
      resource_group = null
      tags           = var.tags
    }
  }
}

check "install_artifact_image_required" {
  assert {
    condition     = local.install_artifact_image != null && local.install_artifact_image != ""
    error_message = "Set install.artifact.image or honua_image."
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

output "install_contract" {
  description = "Provider-neutral install contract for marketplace questionnaires and bundle automation."
  value       = local.install_contract
}

output "deploy_contract" {
  description = "Uniform deploy contract for marketplace automation."
  value       = module.honua.control_plane_contract
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

output "app_storage_enabled" {
  value = module.honua.app_storage_enabled
}

output "app_storage_bucket_name" {
  value = module.honua.app_storage_bucket_name
}

output "app_storage_bucket_arn" {
  value = module.honua.app_storage_bucket_arn
}

output "app_storage_prefix" {
  value = module.honua.app_storage_prefix
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
