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
    "Microsoft.ContainerService/managedClusters/read",
    "Microsoft.ContainerService/managedClusters/write",
    "Microsoft.ContainerService/managedClusters/delete",
    "Microsoft.ContainerService/managedClusters/listClusterAdminCredential/action",
    "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action",
    "Microsoft.ContainerService/managedClusters/agentPools/read",
    "Microsoft.ContainerService/managedClusters/agentPools/write",
    "Microsoft.ContainerService/managedClusters/agentPools/delete",
    "Microsoft.Insights/diagnosticSettings/read",
    "Microsoft.Insights/diagnosticSettings/write",
    "Microsoft.Insights/diagnosticSettings/delete",
    "Microsoft.OperationalInsights/workspaces/read",
    ], local.allow_resource_group_lifecycle ? [
    "Microsoft.Resources/subscriptions/resourceGroups/write",
    "Microsoft.Resources/subscriptions/resourceGroups/delete",
  ] : [])
}

check "federated_inputs_together" {
  assert {
    condition     = (trimspace(var.federated_issuer) == "" && trimspace(var.federated_subject) == "") || (trimspace(var.federated_issuer) != "" && trimspace(var.federated_subject) != "")
    error_message = "federated_issuer and federated_subject must be configured together."
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
  count          = trimspace(var.federated_issuer) != "" && trimspace(var.federated_subject) != "" ? 1 : 0
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
