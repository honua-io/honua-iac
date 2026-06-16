###############################################################################
# Outputs — the non-secret wiring the operator copies into GitHub Actions
# repository VARIABLES (vars.*), plus identifiers for the federated login.
#
# No secret VALUES are output. Secret values live in the vault and are read at
# smoke time by the federated identity; they never transit Terraform output.
###############################################################################

output "resource_group_name" {
  description = "Resource group holding the smoke credential store."
  value       = azurerm_resource_group.this.name
}

output "key_vault_name" {
  description = "Key Vault that holds the seeded cloud-demo smoke secrets."
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Key Vault data-plane URI."
  value       = azurerm_key_vault.this.vault_uri
}

output "smoke_identity_client_id" {
  description = "Client ID of the OIDC-federated smoke identity. Set as the AZURE_CLIENT_ID repo secret/variable for azure/login@v2."
  value       = azurerm_user_assigned_identity.smoke.client_id
}

output "smoke_identity_principal_id" {
  description = "Principal (object) ID of the smoke identity, for auditing the Key Vault access policy."
  value       = azurerm_user_assigned_identity.smoke.principal_id
}

output "tenant_id" {
  description = "Azure tenant ID — set as the AZURE_TENANT_ID repo secret/variable for azure/login@v2."
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Azure subscription ID — set as the AZURE_SUBSCRIPTION_ID repo secret/variable for azure/login@v2."
  value       = data.azurerm_client_config.current.subscription_id
}

# Non-secret env the scheduled smoke needs as repository VARIABLES (vars.*).
output "cloud_demo_repo_variables" {
  description = "Copy these into GitHub Actions repository VARIABLES (Settings > Secrets and variables > Actions > Variables) for the cloud-demo-smoke workflow."
  value = {
    HONUA_CLOUD_DEMO_ENABLED         = "true"
    HONUA_CLOUD_DEMO_BASE_URL        = var.cloud_demo_base_url
    HONUA_CLOUD_DEMO_METADATA_TTL_MS = tostring(var.cloud_demo_metadata_ttl_ms)
    HONUA_CLOUD_DEMO_ALLOW_WRITES    = var.enable_writable_lane ? "true" : "false"
    VITE_HONUA_INCIDENT_TRANSPORT    = "cloud"
    VITE_HONUA_INCIDENT_STREAM_URL   = var.cloud_demo_stream_url
  }
}

# Names (NOT values) of the secret slots the operator must populate.
output "secret_slot_names" {
  description = "Key Vault secret names the operator must populate with `az keyvault secret set`. The smoke reads these and exports them as the matching HONUA_CLOUD_DEMO_* env."
  value = compact([
    azurerm_key_vault_secret.read_api_key.name,
    azurerm_key_vault_secret.bearer_token.name,
    var.enable_writable_lane ? azurerm_key_vault_secret.write_token[0].name : "",
    var.enable_writable_lane ? azurerm_key_vault_secret.reset_token[0].name : "",
    var.enable_writable_lane ? azurerm_key_vault_secret.reset_url[0].name : "",
  ])
}
