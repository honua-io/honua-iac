// Compatibility wrapper around the canonical implementation.

module "platform" {
  source = "../../platforms/azure-aks"

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
  local_account_disabled                = var.local_account_disabled
  admin_group_object_ids                = var.admin_group_object_ids
  grant_current_principal_cluster_admin = var.grant_current_principal_cluster_admin
  auto_scaling_enabled                  = var.auto_scaling_enabled
  node_min_count                        = var.node_min_count
  node_max_count                        = var.node_max_count
  network_plugin                        = var.network_plugin
  network_policy                        = var.network_policy
  log_analytics_workspace_id            = var.log_analytics_workspace_id
  acr_resource_id                       = var.acr_resource_id
}
