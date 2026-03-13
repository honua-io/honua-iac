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
