###############################################################################
# Seeded cloud-demo smoke credential store (honua-iac#30)
#
# Provides the managed credential + secret-store half of REQ-002 / REQ-004 /
# NFR-001 for the seeded Honua Cloud demo tenant. It does NOT seed the demo
# data or stand up the API (that is the demo-environment Terraform / honua
# modules and honua-server#1688); it makes the smoke credentials available to
# the already-merged scheduled smoke workflow
# (.github/workflows/cloud-demo-smoke.yml) through a managed identity, so the
# JS `npm run test:cloud-demo:staging` lane can authenticate without any secret
# being committed to the repo.
#
# Contract source of truth: honua-sdk-js/examples/cloud-demo-services.json and
# examples/cloud-demo.env.example (the HONUA_CLOUD_DEMO_* / VITE_* names).
#
# Fail-closed posture (NFR-001):
#   - Read API key + bearer token slots always exist (read-only smoke).
#   - Write token + reset token slots only exist when enable_writable_lane=true.
#   - A check block asserts that a reset_url is present whenever the writable
#     lane is enabled, so writes cannot be turned on without a reset path.
###############################################################################

data "azurerm_client_config" "current" {}

locals {
  name = "${var.name_prefix}-${var.environment}"
  tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "cloud-demo-smoke-credentials"
    Issue       = "honua-iac#30"
  }, var.tags)
}

# REQ-004 / NFR-001 guard: writes cannot be provisioned without a reset path.
check "writable_requires_reset" {
  assert {
    condition     = !var.enable_writable_lane || trimspace(var.cloud_demo_reset_url) != ""
    error_message = "enable_writable_lane=true requires cloud_demo_reset_url; the writable seeded smoke must fail closed when no reset endpoint exists (NFR-001)."
  }
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name}-smoke-rg"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# Smoke identity (OIDC-federated; no client secret).
# The scheduled GitHub Actions smoke assumes this identity via azure/login and
# reads the demo credentials from the vault below.
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "smoke" {
  name                = "${local.name}-smoke-identity"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "smoke" {
  name                = "${local.name}-smoke-gha"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.smoke.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = var.github_oidc_subject
}

# ---------------------------------------------------------------------------
# Key Vault — the managed secret store (REQ-002).
# ---------------------------------------------------------------------------

#checkov:skip=CKV_AZURE_189: Demo smoke credential store; runner reaches the data plane over the public endpoint gated by network ACLs (key_vault_ip_rules), not a private endpoint.
#checkov:skip=CKV2_AZURE_32: Private endpoint not used for this demo credential vault; access is gated by network ACLs + the federated smoke identity.
resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV_AZURE_189: see resource note.
  #checkov:skip=CKV2_AZURE_32: see resource note.
  name                          = substr(replace("${local.name}smokekv", "-", ""), 0, 24)
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  purge_protection_enabled      = var.key_vault_purge_protection_enabled
  soft_delete_retention_days    = var.key_vault_soft_delete_retention_days
  public_network_access_enabled = var.key_vault_public_network_access_enabled

  network_acls {
    default_action = var.key_vault_default_action
    bypass         = var.key_vault_bypass
    ip_rules       = var.key_vault_ip_rules
  }

  tags = local.tags
}

# Apply-time identity (operator / CI deploy principal) — manages secret values.
resource "azurerm_key_vault_access_policy" "current" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Purge",
    "Recover",
  ]
}

# Smoke identity — read-only on secrets (least privilege for the scheduled run).
resource "azurerm_key_vault_access_policy" "smoke" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.smoke.principal_id

  secret_permissions = [
    "Get",
    "List",
  ]
}

# ---------------------------------------------------------------------------
# Secret SLOTS. Values are placeholders that the operator overwrites out of
# band (az keyvault secret set ...). Terraform manages the slot + metadata, and
# ignores subsequent value drift so a credential rotation does not show as a
# Terraform change (rotation is operational, not a code change — see README).
# ---------------------------------------------------------------------------

# Read-only smoke credentials (always provisioned).
resource "azurerm_key_vault_secret" "read_api_key" {
  name         = "honua-cloud-demo-api-key"
  value        = "REPLACE_VIA_AZ_KEYVAULT_SECRET_SET"
  key_vault_id = azurerm_key_vault.this.id
  content_type = "HONUA_CLOUD_DEMO_API_KEY"
  tags         = local.tags
  depends_on   = [azurerm_key_vault_access_policy.current]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "bearer_token" {
  name         = "honua-cloud-demo-bearer-token"
  value        = "REPLACE_VIA_AZ_KEYVAULT_SECRET_SET"
  key_vault_id = azurerm_key_vault.this.id
  content_type = "HONUA_CLOUD_DEMO_BEARER_TOKEN"
  tags         = local.tags
  depends_on   = [azurerm_key_vault_access_policy.current]

  lifecycle {
    ignore_changes = [value]
  }
}

# Guarded writable lane (only when enable_writable_lane = true).
resource "azurerm_key_vault_secret" "write_token" {
  count        = var.enable_writable_lane ? 1 : 0
  name         = "honua-cloud-demo-write-token"
  value        = "REPLACE_VIA_AZ_KEYVAULT_SECRET_SET"
  key_vault_id = azurerm_key_vault.this.id
  content_type = "HONUA_CLOUD_DEMO_WRITE_TOKEN"
  tags         = local.tags
  depends_on   = [azurerm_key_vault_access_policy.current]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "reset_token" {
  count        = var.enable_writable_lane ? 1 : 0
  name         = "honua-cloud-demo-reset-token"
  value        = "REPLACE_VIA_AZ_KEYVAULT_SECRET_SET"
  key_vault_id = azurerm_key_vault.this.id
  content_type = "HONUA_CLOUD_DEMO_RESET_TOKEN"
  tags         = local.tags
  depends_on   = [azurerm_key_vault_access_policy.current]

  lifecycle {
    ignore_changes = [value]
  }
}

# Reset URL is stored as a secret slot (server-side only) so it never leaks into
# VITE_*. Unlike the tokens, its value IS managed by Terraform (it is config,
# not a minted secret).
resource "azurerm_key_vault_secret" "reset_url" {
  count        = var.enable_writable_lane ? 1 : 0
  name         = "honua-cloud-demo-reset-url"
  value        = var.cloud_demo_reset_url
  key_vault_id = azurerm_key_vault.this.id
  content_type = "HONUA_CLOUD_DEMO_RESET_URL"
  tags         = local.tags
  depends_on   = [azurerm_key_vault_access_policy.current]
}
