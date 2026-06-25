###############################################################################
# Outputs — the cross-repo runtime contract (v1) for the Azure GP substrate.
#
# The honua-devops gp runtime adapter + the server's AzureBatchComputeBackend
# consume these as OPAQUE runtime config — they couple to the exported
# endpoints/ids, NOT to terraform variable names. The param-key strings the
# server reads (verified against honua-server AzureBatchComputeBackend.cs) are:
#   - azure.batch.account_url           <- gp_batch_account_url
#   - azure.batch.pool_id               <- gp_pool_id
#   - azure.storage.output_container_url<- gp_output_container_url
#   - Backend id "honua-azure-batch"    <- gp_control_plane_backend_name
# All null when enable_azure_gp_substrate is false.
###############################################################################

output "azure_gp_enabled" {
  description = "Whether the Azure GP-on-Batch substrate was provisioned."
  value       = local.gp_enabled
}

output "gp_batch_account_url" {
  description = "Batch account data-plane endpoint. The server reads this as azure.batch.account_url. The account_endpoint is the hostname; prefixed with https:// to form the data-plane URL the Batch client expects."
  value       = local.gp_enabled ? "https://${azurerm_batch_account.gp[0].account_endpoint}" : null
}

output "gp_pool_id" {
  description = "Id of the single GP Batch pool. The server reads this as azure.batch.pool_id."
  value       = local.gp_enabled ? azurerm_batch_pool.gp[0].name : null
}

output "gp_batch_account_id" {
  description = "Azure resource id of the Batch account."
  value       = local.gp_enabled ? azurerm_batch_account.gp[0].id : null
}

output "gp_batch_account_name" {
  description = "Name of the Batch account."
  value       = local.gp_enabled ? azurerm_batch_account.gp[0].name : null
}

output "gp_task_identity_id" {
  description = "Resource id of the user-assigned identity the GP pool/tasks run under (the IAM job-role equivalent)."
  value       = local.gp_enabled ? azurerm_user_assigned_identity.gp_task[0].id : null
}

output "gp_task_identity_principal_id" {
  description = "Principal (object) id of the GP task identity — for auditing its ACR/blob/Key Vault role assignments."
  value       = local.gp_enabled ? azurerm_user_assigned_identity.gp_task[0].principal_id : null
}

output "gp_task_identity_client_id" {
  description = "Client id of the GP task identity — used by az login --identity inside the pool start_task."
  value       = local.gp_enabled ? azurerm_user_assigned_identity.gp_task[0].client_id : null
}

output "gp_acr_login_server" {
  description = "Login server of the worker-gdal ACR (for image push/pull). Null unless create_worker_gdal_acr."
  value       = local.gp_enabled && var.create_worker_gdal_acr ? azurerm_container_registry.worker_gdal[0].login_server : null
}

output "gp_acr_id" {
  description = "Resource id of the worker-gdal ACR (null unless create_worker_gdal_acr)."
  value       = local.gp_enabled && var.create_worker_gdal_acr ? azurerm_container_registry.worker_gdal[0].id : null
}

output "gp_output_container_url" {
  description = "Blob container URL the GP tasks upload output to. The server reads this as azure.storage.output_container_url."
  value       = local.gp_enabled ? "${azurerm_storage_account.gp_output[0].primary_blob_endpoint}${azurerm_storage_container.gp_output[0].name}" : null
}

output "gp_output_storage_account_name" {
  description = "Name of the GP output storage account."
  value       = local.gp_enabled ? azurerm_storage_account.gp_output[0].name : null
}

output "gp_output_storage_account_id" {
  description = "Resource id of the GP output storage account (for scoping blob role assignments)."
  value       = local.gp_enabled ? azurerm_storage_account.gp_output[0].id : null
}

output "gp_resource_group_name" {
  description = "Resource group holding the Azure GP substrate."
  value       = local.gp_enabled ? azurerm_resource_group.this[0].name : null
}

output "gp_control_plane_backend_name" {
  description = "Backend name the reconciler matches to dispatch to the Azure Batch adapter. Matches AzureBatchComputeBackend.BackendIdentifier."
  value       = "honua-azure-batch"
}
