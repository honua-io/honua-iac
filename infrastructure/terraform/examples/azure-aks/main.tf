provider "azurerm" {
  features {}
}

module "aks" {
  source = "../../modules/azure-aks"

  name_prefix                           = var.name_prefix
  environment                           = var.environment
  location                              = var.location
  tags                                  = var.tags
  node_count                            = var.node_count
  node_vm_size                          = var.node_vm_size
  node_os_disk_size_gb                  = var.node_os_disk_size_gb
  kubernetes_version                    = var.kubernetes_version
  sku_tier                              = var.sku_tier
  authorized_ip_ranges                  = var.authorized_ip_ranges
  grant_current_principal_cluster_admin = var.grant_current_principal_cluster_admin
  acr_resource_id                       = var.acr_resource_id
}

locals {
  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "azure-aks"
      platform    = "azure-aks"
      runtime     = "kubernetes"
      environment = var.environment
      region      = var.location
    }
    workload = {
      kind           = module.aks.control_plane_target_kind
      name           = module.aks.cluster_name
      resource_id    = module.aks.cluster_id
      resource_group = module.aks.resource_group_name
      metrics_hint   = module.aks.honua_metrics_target
    }
    rollout = {
      backend_name          = module.aks.control_plane_backend_name
      target_id             = "${var.environment}-${module.aks.cluster_name}"
      target_name           = module.aks.cluster_name
      target_resource_id    = module.aks.cluster_id
      target_resource_group = module.aks.resource_group_name
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "azure-aks"
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
      telemetry_policy = module.aks.control_plane_telemetry_policy
    }
    grouping = {
      region         = var.location
      resource_group = module.aks.resource_group_name
      tags           = var.tags
    }
    cluster = {
      metrics_target = module.aks.honua_metrics_target
    }
  }

  infrastructure_outputs = {
    environment = module.aks.environment
    location    = var.location
    cluster = {
      name                = module.aks.cluster_name
      id                  = module.aks.cluster_id
      resource_group_name = module.aks.resource_group_name
      metrics_target      = module.aks.honua_metrics_target
    }
  }

  honua_integration_outputs = {
    control_plane = {
      target_kind      = module.aks.control_plane_target_kind
      backend_name     = module.aks.control_plane_backend_name
      telemetry_policy = module.aks.control_plane_telemetry_policy
    }
    contracts = {
      deployment = local.deployment_contract
      validation = local.validation_contract
      operations = local.operations_contract
    }
  }
}

output "resource_group_name" {
  value = module.aks.resource_group_name
}

output "environment" {
  value = module.aks.environment
}

output "cluster_name" {
  value = module.aks.cluster_name
}

output "cluster_id" {
  value = module.aks.cluster_id
}

output "control_plane_target_kind" {
  value = module.aks.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.aks.control_plane_backend_name
}

output "control_plane_telemetry_policy" {
  value = module.aks.control_plane_telemetry_policy
}

output "honua_metrics_target" {
  value = module.aks.honua_metrics_target
}

output "infrastructure_outputs" {
  value = local.infrastructure_outputs
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
