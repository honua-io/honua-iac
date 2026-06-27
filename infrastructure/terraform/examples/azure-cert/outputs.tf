###############################################################################
# Outputs — the GP substrate runtime contract (opaque endpoints/ids the devops
# adapter + server read) plus the OIDC wiring the cert workflow needs.
###############################################################################

# --- GP substrate runtime contract (azure.batch.* / azure.storage.*) -------

output "gp_batch_account_url" {
  description = "Batch account data-plane URL. The server reads this as azure.batch.account_url."
  value       = module.azure_gp.gp_batch_account_url
}

output "gp_pool_id" {
  description = "Single GP Batch pool id. The server reads this as azure.batch.pool_id."
  value       = module.azure_gp.gp_pool_id
}

output "gp_output_container_url" {
  description = "GP output blob container URL. The server reads this as azure.storage.output_container_url."
  value       = module.azure_gp.gp_output_container_url
}

output "gp_control_plane_backend_name" {
  description = "Backend id the reconciler matches to dispatch to the Azure Batch adapter (honua-azure-batch)."
  value       = module.azure_gp.gp_control_plane_backend_name
}

output "gp_acr_login_server" {
  description = "Login server of the cert worker-gdal ACR (for image push). Null unless create_worker_gdal_acr."
  value       = module.azure_gp.gp_acr_login_server
}

output "gp_task_identity_principal_id" {
  description = "Principal id of the GP task identity (the pool/task run-as identity)."
  value       = module.azure_gp.gp_task_identity_principal_id
}

# --- OIDC federation wiring (set these as GitHub Actions repo secrets/vars) -

output "cert_identity_client_id" {
  description = "Client id of the OIDC-federated cert identity. Set as AZURE_CLIENT_ID for azure/login@v2."
  value       = azurerm_user_assigned_identity.cert.client_id
}

output "cert_identity_principal_id" {
  description = "Principal (object) id of the cert identity — for auditing its role assignments."
  value       = azurerm_user_assigned_identity.cert.principal_id
}

output "tenant_id" {
  description = "Azure tenant id — set as AZURE_TENANT_ID for azure/login@v2."
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Azure subscription id — set as AZURE_SUBSCRIPTION_ID for azure/login@v2."
  value       = data.azurerm_client_config.current.subscription_id
}
