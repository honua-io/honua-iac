provider "azurerm" {
  features {}
}

module "aks" {
  source = "../../modules/azure-aks"

  name_prefix             = var.name_prefix
  environment             = var.environment
  location                = var.location
  tags                    = var.tags
  node_count              = var.node_count
  node_vm_size            = var.node_vm_size
  node_os_disk_size_gb    = var.node_os_disk_size_gb
  auto_scaling_enabled    = var.auto_scaling_enabled
  node_min_count          = var.node_min_count
  node_max_count          = var.node_max_count
  kubernetes_version      = var.kubernetes_version
  sku_tier                = var.sku_tier
  authorized_ip_ranges    = var.authorized_ip_ranges
  managed_aad_enabled     = var.managed_aad_enabled
  local_account_disabled  = var.local_account_disabled
  private_cluster_enabled = var.private_cluster_enabled
}

locals {
  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "azure-aks"
      platform    = "kubernetes"
      runtime     = "kubernetes"
      environment = var.environment
      region      = var.location
    }
    endpoints = {
      public_base_url = null
      readiness_url   = null
      admin_url       = null
      protocol_url    = null
    }
    workload = {
      kind        = module.aks.control_plane_target_kind
      name        = module.aks.cluster_name
      resource_id = module.aks.cluster_id
    }
    rollout = {
      backend_name       = module.aks.control_plane_backend_name
      target_id          = module.aks.cluster_name
      target_name        = module.aks.cluster_name
      target_resource_id = module.aks.cluster_id
      current_revision   = var.kubernetes_version != "" ? var.kubernetes_version : null
      desired_revision   = var.kubernetes_version != "" ? var.kubernetes_version : null
    }
    dependencies = {
      cluster = {
        kind                 = "azure-aks"
        resource_group_name  = module.aks.resource_group_name
        authorized_ip_ranges = var.authorized_ip_ranges
        private_cluster      = var.private_cluster_enabled
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
      cluster_name   = module.aks.cluster_name
      cluster_id     = module.aks.cluster_id
      resource_group = module.aks.resource_group_name
      metrics_target = module.aks.honua_metrics_target
      region         = var.location
    }
    lifecycle = {
      reuse_data_stack = false
      destroy_mode     = "explicit"
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy      = module.aks.control_plane_telemetry_policy
      prometheus_job        = module.aks.honua_metrics_target
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
      resource_group = module.aks.resource_group_name
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

output "resource_group_name" {
  description = "Azure resource group containing the AKS cluster."
  value       = module.aks.resource_group_name
}

output "environment" {
  description = "Deployment environment name."
  value       = module.aks.environment
}

output "cluster_name" {
  description = "AKS cluster name."
  value       = module.aks.cluster_name
}

output "cluster_id" {
  description = "AKS cluster resource ID."
  value       = module.aks.cluster_id
}

output "control_plane_target_kind" {
  description = "Control-plane target kind emitted by the AKS module."
  value       = module.aks.control_plane_target_kind
}

output "control_plane_backend_name" {
  description = "Control-plane backend name emitted by the AKS module."
  value       = module.aks.control_plane_backend_name
}

output "control_plane_telemetry_policy" {
  description = "Telemetry policy advertised by the AKS module."
  value       = module.aks.control_plane_telemetry_policy
}

output "honua_metrics_target" {
  description = "Prometheus scrape target metadata for Honua on AKS."
  value       = module.aks.honua_metrics_target
}
