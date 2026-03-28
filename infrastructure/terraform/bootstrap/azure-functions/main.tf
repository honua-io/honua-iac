terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

data "azurerm_subscription" "current" {}

data "azurerm_client_config" "current" {}

locals {
  scope                          = var.scope != "" ? var.scope : data.azurerm_subscription.current.id
  scope_is_resource_group        = can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+$", local.scope))
  allow_resource_group_lifecycle = var.allow_resource_group_lifecycle != null ? var.allow_resource_group_lifecycle : !local.scope_is_resource_group
  role_actions = concat([
    "Microsoft.Resources/subscriptions/read",
    "Microsoft.Resources/subscriptions/resources/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.ManagedIdentity/userAssignedIdentities/read",
    "Microsoft.ManagedIdentity/userAssignedIdentities/write",
    "Microsoft.ManagedIdentity/userAssignedIdentities/delete",
    "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action",
    "Microsoft.ContainerRegistry/registries/read",
    "Microsoft.ContainerRegistry/registries/listCredentials/action",
    "Microsoft.Insights/diagnosticSettings/read",
    "Microsoft.Insights/diagnosticSettings/write",
    "Microsoft.Insights/diagnosticSettings/delete",
    "Microsoft.KeyVault/locations/deletedVaults/read",
    "Microsoft.KeyVault/vaults/read",
    "Microsoft.KeyVault/vaults/write",
    "Microsoft.KeyVault/vaults/delete",
    "Microsoft.KeyVault/vaults/accessPolicies/write",
    "Microsoft.Storage/storageAccounts/read",
    "Microsoft.Storage/storageAccounts/write",
    "Microsoft.Storage/storageAccounts/delete",
    "Microsoft.Storage/storageAccounts/listkeys/action",
    "Microsoft.Storage/storageAccounts/regeneratekey/action",
    "Microsoft.Storage/storageAccounts/fileServices/read",
    "Microsoft.Storage/storageAccounts/blobServices/read",
    "Microsoft.Storage/storageAccounts/blobServices/write",
    "Microsoft.Storage/storageAccounts/blobServices/containers/read",
    "Microsoft.Storage/storageAccounts/blobServices/containers/write",
    "Microsoft.Storage/storageAccounts/blobServices/containers/delete",
    "Microsoft.Storage/storageAccounts/queueServices/read",
    "Microsoft.Storage/storageAccounts/queueServices/write",
    "Microsoft.Storage/storageAccounts/tableServices/read",
    "Microsoft.Storage/storageAccounts/tableServices/write",
    "Microsoft.DBforPostgreSQL/locations/azureAsyncOperation/read",
    "Microsoft.DBforPostgreSQL/flexibleServers/read",
    "Microsoft.DBforPostgreSQL/flexibleServers/write",
    "Microsoft.DBforPostgreSQL/flexibleServers/delete",
    "Microsoft.DBforPostgreSQL/flexibleServers/databases/read",
    "Microsoft.DBforPostgreSQL/flexibleServers/databases/write",
    "Microsoft.DBforPostgreSQL/flexibleServers/databases/delete",
    "Microsoft.DBforPostgreSQL/flexibleServers/configurations/read",
    "Microsoft.DBforPostgreSQL/flexibleServers/configurations/write",
    "Microsoft.DBforPostgreSQL/flexibleServers/firewallRules/read",
    "Microsoft.DBforPostgreSQL/flexibleServers/firewallRules/write",
    "Microsoft.DBforPostgreSQL/flexibleServers/firewallRules/delete",
    "Microsoft.Cache/Redis/read",
    "Microsoft.Cache/Redis/write",
    "Microsoft.Cache/Redis/delete",
    "Microsoft.Cache/Redis/listKeys/action",
    "Microsoft.Insights/components/read",
    "Microsoft.Insights/components/write",
    "Microsoft.Insights/components/delete",
    "Microsoft.Insights/components/currentbillingfeatures/write",
    "Microsoft.OperationalInsights/workspaces/read",
    "Microsoft.OperationalInsights/workspaces/write",
    "Microsoft.OperationalInsights/workspaces/delete",
    "Microsoft.OperationalInsights/workspaces/sharedkeys/action",
    "Microsoft.Web/serverfarms/read",
    "Microsoft.Web/serverfarms/write",
    "Microsoft.Web/serverfarms/delete",
    "Microsoft.Web/sites/read",
    "Microsoft.Web/sites/write",
    "Microsoft.Web/sites/delete",
    "Microsoft.Web/sites/basicPublishingCredentialsPolicies/read",
    "Microsoft.Web/sites/config/read",
    "Microsoft.Web/sites/config/list/action",
    "Microsoft.Web/sites/config/write",
    "Microsoft.Web/sites/slots/read",
    "Microsoft.Web/sites/slots/write",
    "Microsoft.Web/sites/slots/delete",
    "Microsoft.Web/sites/slots/basicPublishingCredentialsPolicies/read",
    "Microsoft.Web/sites/slots/config/read",
    "Microsoft.Web/sites/slots/config/list/action",
    "Microsoft.Web/sites/slots/config/write",
    ], local.allow_resource_group_lifecycle ? [
    "Microsoft.Resources/subscriptions/resourceGroups/write",
    "Microsoft.Resources/subscriptions/resourceGroups/delete",
    ] : [], var.allow_role_assignment_management ? [
    "Microsoft.Authorization/roleAssignments/read",
    "Microsoft.Authorization/roleAssignments/write",
    "Microsoft.Authorization/roleAssignments/delete",
  ] : [])
}

check "federated_inputs_together" {
  assert {
    condition     = (trimspace(var.federated_issuer) == "" && trimspace(var.federated_subject) == "") || (trimspace(var.federated_issuer) != "" && trimspace(var.federated_subject) != "")
    error_message = "federated_issuer and federated_subject must be set together."
  }
}

resource "azuread_application" "terraform" {
  display_name = var.app_name
}

resource "azuread_service_principal" "terraform" {
  client_id = azuread_application.terraform.client_id
}

resource "azuread_service_principal_password" "terraform" {
  count                = var.create_client_secret ? 1 : 0
  service_principal_id = azuread_service_principal.terraform.object_id
  end_date_relative    = "${var.service_principal_secret_duration_hours}h"
}

resource "azuread_application_federated_identity_credential" "terraform" {
  count = trimspace(var.federated_issuer) != "" && trimspace(var.federated_subject) != "" ? 1 : 0

  application_id = azuread_application.terraform.id
  display_name   = var.federated_credential_display_name
  issuer         = var.federated_issuer
  subject        = var.federated_subject
  audiences      = var.federated_audiences
}

resource "azurerm_role_definition" "terraform" {
  name  = var.role_name
  scope = local.scope

  permissions {
    actions     = local.role_actions
    not_actions = []
  }

  assignable_scopes = [local.scope]
}

resource "azurerm_role_assignment" "terraform" {
  principal_id       = azuread_service_principal.terraform.object_id
  role_definition_id = azurerm_role_definition.terraform.role_definition_resource_id
  scope              = local.scope
}
