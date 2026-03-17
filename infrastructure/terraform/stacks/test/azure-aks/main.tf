// Validation stack wrapper around the canonical customer stack.

module "stack" {
  source = "../../customer/azure-aks"

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
  value = module.stack.resource_group_name
}

output "environment" {
  value = module.stack.environment
}

output "cluster_name" {
  value = module.stack.cluster_name
}

output "cluster_id" {
  value = module.stack.cluster_id
}

output "control_plane_target_kind" {
  value = module.stack.control_plane_target_kind
}

output "control_plane_backend_name" {
  value = module.stack.control_plane_backend_name
}

output "control_plane_telemetry_policy" {
  value = module.stack.control_plane_telemetry_policy
}

output "honua_metrics_target" {
  value = module.stack.honua_metrics_target
}

output "infrastructure_outputs" {
  value = module.stack.infrastructure_outputs
}

output "honua_integration_outputs" {
  value = module.stack.honua_integration_outputs
}

output "deployment_contract" {
  value = module.stack.deployment_contract
}

output "validation_contract" {
  value = module.stack.validation_contract
}

output "operations_contract" {
  value = module.stack.operations_contract
}
