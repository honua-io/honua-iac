locals {
  name = "${var.name_prefix}-${var.environment}"
  tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.tags)
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  name     = "${local.name}-aks-rg"
  location = var.location
  tags     = local.tags
}

#checkov:skip=CKV_AZURE_4: Diagnostics are configured separately when a Log Analytics workspace is provided.
#checkov:skip=CKV_AZURE_115: Private-cluster networking is environment-specific and can be enabled by the caller.
#checkov:skip=CKV_AZURE_116: Azure Policy enablement is environment-specific and may be layered on later.
#checkov:skip=CKV_AZURE_117: Disk encryption sets are optional and managed outside this module.
#checkov:skip=CKV_AZURE_168: Node-pool density is environment-specific and intentionally configurable.
#checkov:skip=CKV_AZURE_170: Free-tier clusters remain valid for MVP and non-production deployments.
#checkov:skip=CKV_AZURE_171: Upgrade channels are managed by operators outside this module.
#checkov:skip=CKV_AZURE_172: Secrets Store autorotation is layered in when CSI integration is enabled.
#checkov:skip=CKV_AZURE_226: Ephemeral OS disks depend on chosen VM sizes and are not universally available.
#checkov:skip=CKV_AZURE_227: Host/storage encryption settings are environment-specific and may be layered on later.
#checkov:skip=CKV_AZURE_232: System-node pod isolation is handled by cluster policy after bootstrap.
resource "azurerm_kubernetes_cluster" "this" {
  #checkov:skip=CKV_AZURE_4: Diagnostics are configured separately when a Log Analytics workspace is provided.
  #checkov:skip=CKV_AZURE_115: Private-cluster networking is environment-specific and can be enabled by the caller.
  #checkov:skip=CKV_AZURE_116: Azure Policy enablement is environment-specific and may be layered on later.
  #checkov:skip=CKV_AZURE_117: Disk encryption sets are optional and managed outside this module.
  #checkov:skip=CKV_AZURE_168: Node-pool density is environment-specific and intentionally configurable.
  #checkov:skip=CKV_AZURE_170: Free-tier clusters remain valid for MVP and non-production deployments.
  #checkov:skip=CKV_AZURE_171: Upgrade channels are managed by operators outside this module.
  #checkov:skip=CKV_AZURE_172: Secrets Store autorotation is layered in when CSI integration is enabled.
  #checkov:skip=CKV_AZURE_226: Ephemeral OS disks depend on chosen VM sizes and are not universally available.
  #checkov:skip=CKV_AZURE_227: Host/storage encryption settings are environment-specific and may be layered on later.
  #checkov:skip=CKV_AZURE_232: System-node pod isolation is handled by cluster policy after bootstrap.
  name                = "${local.name}-aks"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = substr(replace("${local.name}aks", "-", ""), 0, 45)
  sku_tier            = var.sku_tier

  kubernetes_version = var.kubernetes_version != "" ? var.kubernetes_version : null

  default_node_pool {
    name                 = "system"
    vm_size              = var.node_vm_size
    node_count           = var.auto_scaling_enabled ? null : var.node_count
    os_disk_size_gb      = var.node_os_disk_size_gb
    auto_scaling_enabled = var.auto_scaling_enabled
    min_count            = var.auto_scaling_enabled ? var.node_min_count : null
    max_count            = var.auto_scaling_enabled ? var.node_max_count : null

    # Pin provider defaults to avoid idempotency drift on repeated plans.
    upgrade_settings {
      max_surge                     = "10%"
      drain_timeout_in_minutes      = 0
      node_soak_duration_in_minutes = 0
    }
  }

  identity {
    type = "SystemAssigned"
  }

  role_based_access_control_enabled = true
  local_account_disabled            = var.local_account_disabled

  azure_active_directory_role_based_access_control {
    tenant_id              = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.authorized_ip_ranges) > 0 ? [1] : []

    content {
      authorized_ip_ranges = var.authorized_ip_ranges
    }
  }

  network_profile {
    network_plugin    = var.network_plugin
    network_policy    = var.network_policy
    load_balancer_sku = "standard"
  }

  tags = local.tags
}

resource "azurerm_role_assignment" "current_principal_cluster_admin" {
  count = var.grant_current_principal_cluster_admin ? 1 : 0

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  count                      = var.log_analytics_workspace_id != "" ? 1 : 0
  name                       = "${local.name}-aks-diagnostics"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "kube-apiserver"
  }

  enabled_log {
    category = "kube-audit"
  }

  enabled_log {
    category = "kube-controller-manager"
  }

  enabled_log {
    category = "kube-scheduler"
  }
}
