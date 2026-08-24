# Canonical Honua Operator Contract v1 producer for the AWS ECS small root.
#
# This output is secretless. It does not infer candidate, backend, actor, or
# state identity. Certified consumers must reject the explicit "unqualified"
# status until #149 supplies authoritative backend and state-lineage evidence.

locals {
  operator_contract_identity = var.operator_contract_identity == null ? {
    status                = "unqualified"
    candidate_digest      = null
    iac_revision          = null
    terraform_version     = null
    provider_lock_digest  = null
    image_digest          = null
    backend_config_digest = null
    state_lineage         = null
    state_serial          = null
    workload_identity     = null
    } : {
    status                = "unqualified"
    candidate_digest      = var.operator_contract_identity.candidate_digest
    iac_revision          = var.operator_contract_identity.iac_revision
    terraform_version     = var.operator_contract_identity.terraform_version
    provider_lock_digest  = var.operator_contract_identity.provider_lock_digest
    image_digest          = var.operator_contract_identity.image_digest
    backend_config_digest = try(var.operator_contract_identity.backend_config_digest, null)
    state_lineage         = try(var.operator_contract_identity.state_lineage, null)
    state_serial          = try(var.operator_contract_identity.state_serial, null)
    workload_identity     = try(var.operator_contract_identity.workload_identity, null)
  }

  deployment_contract = {
    schema_version = "v1"
    identity       = local.operator_contract_identity
    stack = {
      id          = "aws-ecs"
      platform    = "aws"
      runtime     = "ecs-fargate"
      environment = var.environment
      region      = var.region
    }
    endpoints = {
      public_base_url = module.honua.service_url
      readiness_path  = "/healthz/ready"
      admin_base_path = "/api/v1/admin"
      protocol_path   = "/v1"
    }
    workload = {
      kind        = module.honua.control_plane_target_kind
      name        = module.honua.ecs_service_name
      resource_id = module.honua.ecs_cluster_name
    }
    rollout = {
      backend_name     = module.honua.control_plane_backend_name
      target_id        = module.honua.ecs_service_name
      target_name      = module.honua.ecs_service_name
      target_resource  = module.honua.ecs_cluster_name
      current_revision = null
      desired_revision = null
    }
    dependencies = {
      database = {
        kind       = "aws-rds-postgres"
        endpoint   = nonsensitive(module.honua.db_endpoint)
        secret_ref = module.honua.db_connection_secret_arn
      }
      cache = {
        kind       = "aws-elasticache-redis"
        enabled    = var.redis_enabled
        secret_ref = nonsensitive(module.honua.redis_connection_secret_arn)
      }
      ingress = {
        kind     = "aws-alb"
        endpoint = module.honua.service_url
      }
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "aws-ecs"
      capabilities = {
        deploy_plan  = true
        mutation     = true
        scale_check  = var.deployment_mode == "MultiNode"
        backup_drill = true
        idempotency  = true
      }
    }
    tests = {
      readiness_url = "${module.honua.service_url}/healthz/ready"
      admin_url     = "${module.honua.service_url}/api/v1/admin"
      protocol_url  = "${module.honua.service_url}/v1"
    }
    artifacts = {
      terraform_root = "infrastructure/terraform/examples/aws"
      module_source  = "infrastructure/terraform/modules/aws-ecs"
      image_digest   = local.operator_contract_identity.image_digest
    }
    lifecycle = {
      reuse_data_stack = var.existing_db_endpoint != ""
      destroy_mode     = var.environment == "prod" ? "protected" : "ephemeral"
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy = module.honua.control_plane_telemetry_policy
      prometheus_job   = module.honua.control_plane_telemetry_prometheus_job
      canary_job       = module.honua.control_plane_telemetry_prometheus_canary_job
    }
    secrets = {
      admin_password_secret   = module.honua.admin_password_secret_arn
      db_connection_secret    = module.honua.db_connection_secret_arn
      redis_connection_secret = nonsensitive(module.honua.redis_connection_secret_arn)
      ai_provider_secret      = var.ai_provider_secret_arn != "" ? var.ai_provider_secret_arn : null
    }
    grouping = {
      resource_group = module.honua.ecs_cluster_name
      tags           = var.tags
    }
    state = {
      backend_config_digest = local.operator_contract_identity.backend_config_digest
      lineage               = local.operator_contract_identity.state_lineage
      serial                = local.operator_contract_identity.state_serial
    }
  }

  operator_contract = {
    schema_version      = "v1"
    deployment_contract = local.deployment_contract
    validation_contract = local.validation_contract
    operations_contract = local.operations_contract
  }
}

output "deployment_contract" {
  description = "Canonical honua.operator-contract/v1 deployment contract for AWS ECS."
  value       = local.deployment_contract
}

output "validation_contract" {
  description = "Canonical honua.operator-contract/v1 validation contract for AWS ECS."
  value       = local.validation_contract
}

output "operations_contract" {
  description = "Canonical honua.operator-contract/v1 operations contract for AWS ECS."
  value       = local.operations_contract
}

output "operator_contract" {
  description = "Canonical honua.operator-contract/v1 envelope containing all three contracts."
  value       = local.operator_contract
}

output "operator_contract_digest" {
  description = "SHA-256 digest of the canonical JSON operator contract envelope."
  value       = sha256(jsonencode(local.operator_contract))
}
