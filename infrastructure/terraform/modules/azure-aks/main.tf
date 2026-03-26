locals {
  name = "${var.name_prefix}-${var.environment}"
  tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.tags)
}

check "node_pool_scaling_bounds" {
  assert {
    condition = (
      (var.auto_scaling_enabled && var.node_max_count >= var.node_min_count) ||
      (!var.auto_scaling_enabled)
    )
    error_message = "node_max_count must be greater than or equal to node_min_count when auto_scaling_enabled is true."
  }
}

check "public_api_requires_authorized_ip_ranges" {
  assert {
    condition     = var.private_cluster_enabled || length(var.authorized_ip_ranges) > 0
    error_message = "Set authorized_ip_ranges when private_cluster_enabled is false."
  }
}

check "local_account_disable_requires_managed_aad" {
  assert {
    condition     = !var.local_account_disabled || var.managed_aad_enabled
    error_message = "Set managed_aad_enabled when local_account_disabled is true."
  }
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name}-aks-rg"
  location = var.location
  tags     = local.tags
}

#checkov:skip=CKV_AZURE_4: Diagnostics are configured separately when a Log Analytics workspace is provided.
#checkov:skip=CKV_AZURE_115: Private DNS integration details remain environment-specific even though private API access is the default.
#checkov:skip=CKV_AZURE_116: Azure Policy enablement is environment-specific and may be layered on later.
#checkov:skip=CKV_AZURE_117: Disk encryption sets are optional and managed outside this module.
#checkov:skip=CKV_AZURE_168: Node-pool density is environment-specific and intentionally configurable.
#checkov:skip=CKV_AZURE_170: Free-tier clusters remain valid for MVP and non-production deployments.
#checkov:skip=CKV_AZURE_171: Upgrade channels are managed by operators outside this module.
#checkov:skip=CKV_AZURE_172: Secrets Store autorotation is layered in when CSI integration is enabled.
#checkov:skip=CKV_AZURE_141: Local admin credentials remain enabled until AKS live validation can use managed Entra auth end-to-end.
#checkov:skip=CKV_AZURE_226: Ephemeral OS disks depend on chosen VM sizes and are not universally available.
#checkov:skip=CKV_AZURE_227: Host/storage encryption settings are environment-specific and may be layered on later.
#checkov:skip=CKV_AZURE_232: System-node pod isolation is handled by cluster policy after bootstrap.
resource "azurerm_kubernetes_cluster" "this" {
  #checkov:skip=CKV_AZURE_4: Diagnostics are configured separately when a Log Analytics workspace is provided.
  #checkov:skip=CKV_AZURE_115: Private DNS integration details remain environment-specific even though private API access is the default.
  #checkov:skip=CKV_AZURE_116: Azure Policy enablement is environment-specific and may be layered on later.
  #checkov:skip=CKV_AZURE_117: Disk encryption sets are optional and managed outside this module.
  #checkov:skip=CKV_AZURE_168: Node-pool density is environment-specific and intentionally configurable.
  #checkov:skip=CKV_AZURE_170: Free-tier clusters remain valid for MVP and non-production deployments.
  #checkov:skip=CKV_AZURE_171: Upgrade channels are managed by operators outside this module.
  #checkov:skip=CKV_AZURE_172: Secrets Store autorotation is layered in when CSI integration is enabled.
  #checkov:skip=CKV_AZURE_141: Local admin credentials remain enabled until AKS live validation can use managed Entra auth end-to-end.
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
  dynamic "azure_active_directory_role_based_access_control" {
    for_each = var.managed_aad_enabled ? [1] : []

    content {
      azure_rbac_enabled = false
    }
  }

  local_account_disabled  = var.local_account_disabled
  private_cluster_enabled = var.private_cluster_enabled

  dynamic "api_server_access_profile" {
    for_each = !var.private_cluster_enabled ? [1] : []

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
