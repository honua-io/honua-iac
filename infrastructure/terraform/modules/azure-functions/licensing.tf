###############################################################################
# Pro license delivery via Key Vault — the Azure mirror of the aws-serverless
# Secrets Manager Pro-license path.
#
# When enabled, the signed Pro license envelope is stored in a dedicated Key
# Vault secret (name `pro-license`) and the server resolves it at startup via
# Licensing__LicenseContentSecretRef. Unlike the runtime app-settings secrets
# (ConnectionStrings__*, which use @Microsoft.KeyVault(...) references resolved
# by the platform), the license uses *server-side* resolution mirroring AWS:
# the env value is `azure:keyvault:<vault-uri>/<secret-name>` and the server
# fetches it with the function's managed identity (#1745 draft). This keeps the
# ~2KB envelope out of the app-settings size budget and matches the AWS
# `aws:secretsmanager:<arn>` contract.
#
# Off by default so existing deploys run Community; when off the secret and env
# are not emitted.
###############################################################################

locals {
  pro_license_enabled = var.enable_pro_license

  # Server-side license reference (ticket #1745):
  #   azure:keyvault:https://<vault>.vault.azure.net/pro-license
  pro_license_secret_ref = local.pro_license_enabled ? "azure:keyvault:${azurerm_key_vault.this.vault_uri}${azurerm_key_vault_secret.pro_license[0].name}" : ""

  pro_license_environment = local.pro_license_enabled ? {
    Licensing__LicenseContentSecretRef                  = local.pro_license_secret_ref
    "Licensing__TrustedKeys__${var.pro_license_key_id}" = var.pro_license_trusted_public_key
  } : {}
}

#checkov:skip=CKV_AZURE_41: Secret expiration is managed by the deployment environment; the license is rotated by re-issuing the envelope.
#checkov:skip=CKV_AZURE_114: Secret content type is not required for server-side reference resolution.
resource "azurerm_key_vault_secret" "pro_license" {
  #checkov:skip=CKV_AZURE_41: Secret expiration is managed by the deployment environment; the license is rotated by re-issuing the envelope.
  #checkov:skip=CKV_AZURE_114: Secret content type is not required for server-side reference resolution.
  count        = local.pro_license_enabled ? 1 : 0
  name         = "pro-license"
  value        = var.pro_license_content
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_key_vault_access_policy.terraform]
}

# Fail the plan early (rather than at runtime) when the Pro license is enabled
# but the envelope or its trusted public key is missing — mirrors the AWS
# terraform_data.pro_license_validation precondition pattern.
resource "terraform_data" "pro_license_validation" {
  count = local.pro_license_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = trimspace(var.pro_license_content) != ""
      error_message = "enable_pro_license is true but pro_license_content (the signed license envelope JSON) is empty."
    }
    precondition {
      condition     = trimspace(var.pro_license_trusted_public_key) != ""
      error_message = "enable_pro_license is true but pro_license_trusted_public_key (the Ed25519 public key) is empty."
    }
  }
}
