data "azurerm_subscription" "current" {}

locals {
  observe_role_name     = "${var.name_prefix} Support Observe"
  break_glass_role_name = "${var.name_prefix} Support Break-Glass"
}

# ---------------------------------------------------------------------------
# Observe role: read-only diagnostics across Honua runtime targets.
#
# Azure RBAC distinguishes management-plane "Actions" (control-plane reads on
# resources) from "DataActions" (reads of the data a resource holds, e.g. a
# Key Vault secret VALUE or a storage blob's bytes). This role grants only
# wildcard control-plane reads (".../read") plus the specific data reads that
# diagnostics genuinely need (log query, metrics). It explicitly grants NO
# Key Vault secret/key/certificate DataActions, so support can inspect Key
# Vault metadata but can never read a secret value.
# ---------------------------------------------------------------------------
resource "azurerm_role_definition" "observe" {
  name        = local.observe_role_name
  scope       = var.scope
  description = "Read-only Honua support diagnostics across ACA, Functions, AKS, PostgreSQL, Redis, networking, logs, and Key Vault metadata. No data-plane secret reads."

  permissions {
    # Control-plane reads across every Honua runtime target. Wildcard ".../read"
    # is read-only by definition in Azure RBAC.
    actions = [
      "Microsoft.Resources/subscriptions/resourceGroups/read",
      "Microsoft.Resources/subscriptions/read",
      "Microsoft.Resources/deployments/read",
      "Microsoft.Resources/deployments/operations/read",

      # Compute runtimes: Container Apps, Functions/App Service, AKS, VMSS/VM.
      "Microsoft.App/*/read",
      "Microsoft.Web/*/read",
      "Microsoft.ContainerService/managedClusters/read",
      "Microsoft.ContainerService/managedClusters/agentPools/read",
      "Microsoft.ContainerService/managedClusters/detectors/read",
      "Microsoft.ContainerRegistry/registries/read",
      "Microsoft.ContainerRegistry/registries/listUsages/action",
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachines/instanceView/read",
      "Microsoft.Compute/virtualMachineScaleSets/read",
      "Microsoft.Compute/virtualMachineScaleSets/instanceView/read",

      # Data + cache: PostgreSQL Flexible Server, Redis.
      "Microsoft.DBforPostgreSQL/flexibleServers/read",
      "Microsoft.DBforPostgreSQL/flexibleServers/configurations/read",
      "Microsoft.DBforPostgreSQL/flexibleServers/databases/read",
      "Microsoft.Cache/redis/read",
      "Microsoft.Cache/redis/firewallRules/read",

      # Networking inspection.
      "Microsoft.Network/*/read",

      # Telemetry: Log Analytics, metrics, Application Insights, alerts.
      "Microsoft.OperationalInsights/workspaces/read",
      "Microsoft.OperationalInsights/workspaces/query/read",
      "Microsoft.Insights/*/read",

      # Key Vault metadata only (control-plane) - never secret values.
      "Microsoft.KeyVault/vaults/read",
      "Microsoft.KeyVault/vaults/secrets/read",
      "Microsoft.KeyVault/vaults/keys/read",

      # Identity + authorization context (read who has what, never grant).
      "Microsoft.ManagedIdentity/userAssignedIdentities/read",
      "Microsoft.Authorization/*/read",
      "Microsoft.Resources/tags/read",
    ]

    not_actions = []

    # Data-plane reads that diagnostics legitimately need. Deliberately excludes
    # Key Vault secret/key/certificate DataActions so secret VALUES stay out of
    # reach even though the control-plane metadata above is readable.
    data_actions = [
      "Microsoft.Insights/Logs/Read",
      "Microsoft.Insights/Metrics/Read",
    ]

    not_data_actions = []
  }

  assignable_scopes = [var.scope]
}

# ---------------------------------------------------------------------------
# Break-glass role: explicit, ticket-scoped remediation. Narrower than the
# built-in Contributor / Owner roles:
# - inherits all observe reads
# - grants targeted "kick it" operational writes (restart/redeploy ACA &
#   Functions, restart AKS/PostgreSQL/Redis, adjust scaling, toggle network
#   security rules)
# - grants NO Microsoft.Authorization/*/write (cannot grant itself or others
#   any role -> no privilege escalation)
# - grants NO Key Vault secret/key DataActions (cannot read or write secret
#   values)
# - grants NO delete on stateful stores (no */delete on PostgreSQL servers,
#   Redis caches, AKS clusters)
#
# Time-bounding is delivered operationally via Entra PIM eligibility (see
# README) rather than a standing assignment; this definition is the ceiling
# that a PIM activation grants for the duration of an approved ticket.
# ---------------------------------------------------------------------------
resource "azurerm_role_definition" "break_glass" {
  name        = local.break_glass_role_name
  scope       = var.scope
  description = "Short-lived elevated Honua support remediation: restart/redeploy/scale workloads and adjust network rules. No role grants, no secret-value access, no deletion of stateful stores. Activate via PIM per ticket."

  permissions {
    actions = [
      # Inherit all observe control-plane reads.
      "Microsoft.Resources/subscriptions/resourceGroups/read",
      "Microsoft.Resources/subscriptions/read",
      "Microsoft.Resources/deployments/read",
      "Microsoft.Resources/deployments/operations/read",
      "Microsoft.App/*/read",
      "Microsoft.Web/*/read",
      "Microsoft.ContainerService/managedClusters/read",
      "Microsoft.ContainerService/managedClusters/agentPools/read",
      "Microsoft.ContainerService/managedClusters/detectors/read",
      "Microsoft.ContainerRegistry/registries/read",
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachines/instanceView/read",
      "Microsoft.Compute/virtualMachineScaleSets/read",
      "Microsoft.Compute/virtualMachineScaleSets/instanceView/read",
      "Microsoft.DBforPostgreSQL/flexibleServers/read",
      "Microsoft.DBforPostgreSQL/flexibleServers/configurations/read",
      "Microsoft.DBforPostgreSQL/flexibleServers/databases/read",
      "Microsoft.Cache/redis/read",
      "Microsoft.Cache/redis/firewallRules/read",
      "Microsoft.Network/*/read",
      "Microsoft.OperationalInsights/workspaces/read",
      "Microsoft.OperationalInsights/workspaces/query/read",
      "Microsoft.Insights/*/read",
      "Microsoft.KeyVault/vaults/read",
      "Microsoft.KeyVault/vaults/secrets/read",
      "Microsoft.KeyVault/vaults/keys/read",
      "Microsoft.ManagedIdentity/userAssignedIdentities/read",
      "Microsoft.Authorization/*/read",
      "Microsoft.Resources/tags/read",

      # Container Apps: redeploy/restart revisions, adjust replicas.
      "Microsoft.App/containerApps/write",
      "Microsoft.App/containerApps/revisions/restart/action",
      "Microsoft.App/containerApps/revisions/activate/action",
      "Microsoft.App/containerApps/revisions/deactivate/action",
      "Microsoft.App/containerApps/stop/action",
      "Microsoft.App/containerApps/start/action",

      # Functions / App Service: restart, redeploy, sync.
      "Microsoft.Web/sites/restart/action",
      "Microsoft.Web/sites/start/action",
      "Microsoft.Web/sites/stop/action",
      "Microsoft.Web/sites/write",
      "Microsoft.Web/sites/config/write",
      "Microsoft.Web/sites/slotsswap/action",

      # AKS: scale node pools, restart cluster, rotate kubeconfig for diagnostics.
      "Microsoft.ContainerService/managedClusters/agentPools/write",
      "Microsoft.ContainerService/managedClusters/start/action",
      "Microsoft.ContainerService/managedClusters/stop/action",
      "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action",

      # PostgreSQL Flexible Server: restart and reload config (no delete).
      "Microsoft.DBforPostgreSQL/flexibleServers/restart/action",
      "Microsoft.DBforPostgreSQL/flexibleServers/configurations/write",
      "Microsoft.DBforPostgreSQL/flexibleServers/start/action",
      "Microsoft.DBforPostgreSQL/flexibleServers/stop/action",

      # Redis: reboot and adjust firewall rules (no delete).
      "Microsoft.Cache/redis/forceReboot/action",
      "Microsoft.Cache/redis/firewallRules/write",

      # Networking: adjust NSG rules to unblock or contain traffic.
      "Microsoft.Network/networkSecurityGroups/securityRules/write",
      "Microsoft.Network/networkSecurityGroups/securityRules/delete",
      "Microsoft.Network/networkSecurityGroups/write",
    ]

    # Hard ceiling: even though some wildcards above could otherwise expand,
    # these NotActions guarantee the role can never grant access or escalate.
    not_actions = [
      "Microsoft.Authorization/roleAssignments/write",
      "Microsoft.Authorization/roleAssignments/delete",
      "Microsoft.Authorization/roleDefinitions/write",
      "Microsoft.Authorization/roleDefinitions/delete",
      "Microsoft.Authorization/denyAssignments/write",
      "Microsoft.Authorization/locks/delete",
      # Never delete stateful stores or whole clusters.
      "Microsoft.DBforPostgreSQL/flexibleServers/delete",
      "Microsoft.Cache/redis/delete",
      "Microsoft.ContainerService/managedClusters/delete",
    ]

    # No Key Vault secret/key/certificate DataActions: break-glass can restart
    # and reconfigure workloads but can never read or write secret VALUES. Log
    # and metric reads remain available for diagnostics during remediation.
    data_actions = [
      "Microsoft.Insights/Logs/Read",
      "Microsoft.Insights/Metrics/Read",
    ]

    not_data_actions = []
  }

  assignable_scopes = [var.scope]
}

# ---------------------------------------------------------------------------
# Assignments
#
# Observe: a standing read-only assignment is acceptable (read-only is safe and
# always needed for diagnostics), so it is created by default.
#
# Break-glass: NO standing assignment by default. Elevated remediation must be
# time-bounded, which on Azure means Entra PIM eligibility activated per ticket
# (an operational step Terraform cannot fully provision). create_break_glass_
# assignment=true is an escape hatch for tenants without PIM and accepts a
# standing assignment you must revoke manually after each incident.
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "observe" {
  for_each = var.create_observe_assignment ? toset(var.observe_principal_object_ids) : toset([])

  scope              = var.scope
  role_definition_id = azurerm_role_definition.observe.role_definition_resource_id
  principal_id       = each.value
  principal_type     = var.principal_type
}

resource "azurerm_role_assignment" "break_glass" {
  for_each = var.create_break_glass_assignment ? toset(var.break_glass_principal_object_ids) : toset([])

  scope              = var.scope
  role_definition_id = azurerm_role_definition.break_glass.role_definition_resource_id
  principal_id       = each.value
  principal_type     = var.principal_type
}
