provider "aws" {
  region = var.region
}

module "eks" {
  source = "../../modules/aws-eks"

  name_prefix                              = var.name_prefix
  environment                              = var.environment
  tags                                     = var.tags
  vpc_cidr                                 = var.vpc_cidr
  public_subnet_cidrs                      = var.public_subnet_cidrs
  private_subnet_cidrs                     = var.private_subnet_cidrs
  cluster_version                          = var.cluster_version
  node_instance_types                      = var.node_instance_types
  node_cpu_architecture                    = var.node_cpu_architecture
  node_min_size                            = var.node_min_size
  node_max_size                            = var.node_max_size
  node_desired_size                        = var.node_desired_size
  cluster_endpoint_public_access           = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
}

locals {
  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "aws-eks"
      platform    = "aws-eks"
      runtime     = "kubernetes"
      environment = var.environment
      region      = var.region
    }
    endpoints = {
      kubernetes_api = module.eks.cluster_endpoint
    }
    workload = {
      kind         = module.eks.control_plane_target_kind
      name         = module.eks.cluster_name
      resource_id  = module.eks.cluster_arn
      vpc_id       = module.eks.vpc_id
      metrics_hint = module.eks.honua_metrics_target
    }
    rollout = {
      backend_name = module.eks.control_plane_backend_name
      target_id    = "${var.environment}-${module.eks.cluster_name}"
      target_name  = module.eks.cluster_name
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "aws-eks"
      capabilities = {
        deploy_plan = false
        mutation    = false
      }
    }
    lifecycle = {
      profile = "ephemeral"
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy = module.eks.control_plane_telemetry_policy
    }
    grouping = {
      region = var.region
      tags   = var.tags
    }
    cluster = {
      oidc_provider          = module.eks.oidc_provider
      oidc_provider_arn      = module.eks.oidc_provider_arn
      metrics_target         = module.eks.honua_metrics_target
      security_group_id      = module.eks.cluster_security_group_id
      node_security_group_id = module.eks.node_security_group_id
    }
  }
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

output "deployment_contract" {
  value = local.deployment_contract
}

output "validation_contract" {
  value = local.validation_contract
}

output "operations_contract" {
  value = local.operations_contract
}
