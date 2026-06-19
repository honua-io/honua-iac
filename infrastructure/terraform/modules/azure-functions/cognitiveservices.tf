###############################################################################
# Azure OpenAI access for the Honua AI studio (workflow / dashboard / report
# generation) — the Azure mirror of aws-serverless/bedrock.tf.
#
# The server's WorkflowGeneration "azureopenai" provider calls Azure OpenAI as a
# Microsoft.Extensions.AI IChatClient, authenticating via Entra Managed Identity
# (the function app's user-assigned identity) rather than an API key — ticket
# #1744 prefers MI auth. Token auth requires the cognitive account to have a
# custom subdomain, and the identity needs the "Cognitive Services OpenAI User"
# role on the account to call the inference (chat completions) data plane.
#
# Without that role assignment the AI console gets 401/403, so this is gated on
# enable_openai_ai (default false) and scoped least-privilege to the single
# account/deployment the server is configured to use.
#
# To avoid Azure OpenAI quota friction an operator can point at an already
# provisioned account by setting openai_account_name (+ openai_account_rg /
# openai_endpoint): the module then references the existing account/endpoint
# instead of creating one, but still lands the role assignment and env.
###############################################################################

locals {
  openai_ai_enabled = var.enable_openai_ai

  # "Use existing account" path: when openai_account_name is set the module
  # references the operator-provisioned account (data source) rather than
  # creating one, sidestepping Azure OpenAI account-quota friction.
  openai_use_existing = var.openai_account_name != ""
  openai_create       = local.openai_ai_enabled && !local.openai_use_existing

  openai_account_id = local.openai_ai_enabled ? (
    local.openai_use_existing ? data.azurerm_cognitive_account.existing[0].id : azurerm_cognitive_account.this[0].id
  ) : null

  # Endpoint surfaced to the server (WorkflowGeneration provider Endpoint). For
  # the existing-account path prefer an explicit override, else the data-source
  # endpoint; for the created path use the new account's endpoint.
  openai_endpoint = local.openai_ai_enabled ? (
    local.openai_use_existing ? (
      var.openai_endpoint != "" ? var.openai_endpoint : data.azurerm_cognitive_account.existing[0].endpoint
    ) : azurerm_cognitive_account.this[0].endpoint
  ) : ""

  # WorkflowGeneration env that routes the AI studio flows to Azure OpenAI.
  # Mirrors the bedrock_ai_environment contract in ASP.NET Core double-underscore
  # form; provider id is exactly `azureopenai` (honua-server #1744 draft).
  openai_ai_environment = local.openai_ai_enabled ? {
    WorkflowGeneration__Enabled                                = "true"
    WorkflowGeneration__DefaultProvider                        = "azureopenai"
    WorkflowGeneration__Providers__azureopenai__Endpoint       = local.openai_endpoint
    WorkflowGeneration__Providers__azureopenai__Model          = var.openai_deployment_name
    WorkflowGeneration__Providers__azureopenai__ApiVersion     = var.openai_api_version
    WorkflowGeneration__Providers__azureopenai__MaxTokens      = tostring(var.openai_max_tokens)
    WorkflowGeneration__Providers__azureopenai__TimeoutSeconds = tostring(var.openai_timeout_seconds)
  } : {}
}

data "azurerm_cognitive_account" "existing" {
  count               = local.openai_ai_enabled && local.openai_use_existing ? 1 : 0
  name                = var.openai_account_name
  resource_group_name = var.openai_account_rg != "" ? var.openai_account_rg : azurerm_resource_group.this.name
}

# Azure OpenAI cognitive account. custom_subdomain_name is required for Entra
# token (managed-identity) auth — without it only key auth works.
#checkov:skip=CKV_AZURE_134: Public network access stays configurable so validation/MVP environments reach the inference endpoint; operators restrict it via network rules outside this module.
#checkov:skip=CKV2_AZURE_22: Customer-managed keys are optional and managed outside this module.
#checkov:skip=CKV_AZURE_247: Outbound network access IS restricted (outbound_network_access_restricted = true); the per-environment FQDN data-exfiltration allowlist is operator-specific and layered on outside this module.
resource "azurerm_cognitive_account" "this" {
  #checkov:skip=CKV_AZURE_134: Public network access stays configurable so validation/MVP environments reach the inference endpoint; operators restrict it via network rules outside this module.
  #checkov:skip=CKV2_AZURE_22: Customer-managed keys are optional and managed outside this module.
  #checkov:skip=CKV_AZURE_247: Outbound network access IS restricted (outbound_network_access_restricted = true); the per-environment FQDN data-exfiltration allowlist is operator-specific and layered on outside this module.
  count               = local.openai_create ? 1 : 0
  name                = "${local.name}-openai"
  location            = var.openai_region != "" ? var.openai_region : azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  kind                = "OpenAI"
  sku_name            = var.openai_sku

  # Required so the account can issue an Entra-token (managed-identity) data-plane
  # endpoint instead of relying on account keys.
  custom_subdomain_name = "${local.name}-openai"

  # Entra-only data plane: the server authenticates via managed identity (the
  # function's UAI + the role assignment below), so disable account-key auth
  # entirely (CKV_AZURE_236). Restrict the account's outbound network access —
  # inference is inbound-only, nothing should egress from the account
  # (CKV_AZURE_247 data-loss-prevention).
  local_auth_enabled                 = false
  outbound_network_access_restricted = true

  # System-assigned identity on the account itself (CKV_AZURE_238) — available
  # for customer-managed-key / outbound scenarios layered on by operators.
  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

resource "azurerm_cognitive_deployment" "model" {
  count                = local.openai_create ? 1 : 0
  name                 = var.openai_deployment_name
  cognitive_account_id = azurerm_cognitive_account.this[0].id

  model {
    format  = "OpenAI"
    name    = var.openai_model
    version = var.openai_model_version != "" ? var.openai_model_version : null
  }

  sku {
    name     = var.openai_deployment_sku
    capacity = var.openai_deployment_capacity
  }
}

# Least-privilege inference grant: the function's managed identity needs the
# "Cognitive Services OpenAI User" role on the account to call chat completions.
resource "azurerm_role_assignment" "function_openai_user" {
  count                = local.openai_ai_enabled ? 1 : 0
  scope                = local.openai_account_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.function.principal_id
}
