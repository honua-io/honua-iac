provider "aws" {
  region = var.region
}

module "eks" {
  source = "../../modules/aws-eks"

  name_prefix          = var.name_prefix
  environment          = var.environment
  tags                 = var.tags
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  cluster_version      = var.cluster_version
  node_instance_types  = var.node_instance_types
  node_min_size        = var.node_min_size
  node_max_size        = var.node_max_size
  node_desired_size    = var.node_desired_size
}

locals {
  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "aws-eks"
      platform    = "kubernetes"
      runtime     = "kubernetes"
      environment = var.environment
      region      = var.region
    }
    endpoints = {
      public_base_url = module.eks.cluster_endpoint
      readiness_url   = null
      admin_url       = null
      protocol_url    = null
    }
    workload = {
      kind        = module.eks.control_plane_target_kind
      name        = module.eks.cluster_name
      resource_id = module.eks.cluster_arn
    }
    rollout = {
      backend_name       = module.eks.control_plane_backend_name
      target_id          = module.eks.cluster_name
      target_name        = module.eks.cluster_name
      target_resource_id = module.eks.cluster_arn
      current_revision   = var.cluster_version
      desired_revision   = var.cluster_version
    }
    dependencies = {
      network = {
        kind                 = "aws-vpc"
        id                   = module.eks.vpc_id
        cidr                 = var.vpc_cidr
        public_subnet_cidrs  = var.public_subnet_cidrs
        private_subnet_cidrs = var.private_subnet_cidrs
      }
      identity = {
        kind              = "aws-iam-oidc-provider"
        oidc_provider     = module.eks.oidc_provider
        oidc_provider_arn = module.eks.oidc_provider_arn
      }
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "kubernetes"
      capabilities = {
        deploy_plan     = true
        mutation        = false
        scale_check     = true
        backup_drill    = false
        idempotency     = true
        protocol_checks = true
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
      cluster_name   = module.eks.cluster_name
      cluster_arn    = module.eks.cluster_arn
      metrics_target = module.eks.honua_metrics_target
      region         = var.region
    }
    lifecycle = {
      reuse_data_stack = false
      destroy_mode     = "explicit"
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy      = module.eks.control_plane_telemetry_policy
      prometheus_job        = module.eks.honua_metrics_target
      prometheus_canary_job = null
      grafana_url           = null
    }
    secrets = {
      secret_store            = null
      admin_password_secret   = null
      db_connection_secret    = null
      redis_connection_secret = null
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
  sensitive   = true
}

output "operations_contract" {
  description = "Stable operations contract for day-2 metadata and secret references."
  value       = local.operations_contract
  sensitive   = true
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "environment" {
  value = module.eks.environment
}

output "cluster_arn" {
  value = module.eks.cluster_arn
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "vpc_id" {
  value = module.eks.vpc_id
}

output "control_plane_target_kind" {
  value = module.eks.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.eks.control_plane_backend_name
}

output "control_plane_telemetry_policy" {
  value = module.eks.control_plane_telemetry_policy
}

output "honua_metrics_target" {
  value = module.eks.honua_metrics_target
}
