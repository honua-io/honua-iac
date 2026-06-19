output "environment" {
  value = var.environment
}

output "function_app_name" {
  value = azurerm_linux_function_app.this.name
}

output "function_app_id" {
  value = azurerm_linux_function_app.this.id
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "function_app_slot_name" {
  value = var.deployment_slot_enabled ? azurerm_linux_function_app_slot.staging[0].name : null
}

output "function_app_slot_id" {
  value = var.deployment_slot_enabled ? azurerm_linux_function_app_slot.staging[0].id : null
}

output "control_plane_target_kind" {
  value = "AzureFunctions"
}

output "control_plane_backend_name" {
  value = "honua-gitops-azure-functions"
}

output "control_plane_target_id" {
  value = azurerm_linux_function_app.this.name
}

output "control_plane_target_name" {
  value = azurerm_linux_function_app.this.name
}

output "control_plane_target_resource_id" {
  value = azurerm_linux_function_app.this.id
}

output "control_plane_target_resource_group" {
  value = azurerm_resource_group.this.name
}

output "control_plane_telemetry_policy" {
  value = "honua-http"
}

output "control_plane_current_revision" {
  value = var.deployment_slot_enabled ? "production" : null
}

output "control_plane_desired_revision" {
  value = var.deployment_slot_enabled ? var.deployment_slot_name : null
}

output "control_plane_slot_name" {
  value = var.deployment_slot_enabled ? azurerm_linux_function_app_slot.staging[0].name : null
}

output "control_plane_current_image" {
  value = var.image
}

output "control_plane_desired_image" {
  value = var.deployment_slot_enabled ? local.slot_image : null
}

output "function_app_url" {
  value = "https://${azurerm_linux_function_app.this.default_hostname}"
}

output "db_fqdn" {
  value     = local.db_server_fqdn
  sensitive = true
}

output "db_connection_string" {
  value     = local.db_connection_string
  sensitive = true
}

output "redis_connection_string" {
  value     = local.redis_connection
  sensitive = true
}

output "redis_connection_secret_id" {
  value     = local.redis_connection != "" ? azurerm_key_vault_secret.redis_connection[0].id : null
  sensitive = true
}

output "openai_ai_enabled" {
  description = "Whether the server is configured to route AI studio (WorkflowGeneration) flows to Azure OpenAI."
  value       = local.openai_ai_enabled
}

output "openai_account_id" {
  description = "Resource ID of the Azure OpenAI account in use (created or referenced; null when disabled)."
  value       = local.openai_account_id
}

output "openai_endpoint" {
  description = "Azure OpenAI endpoint surfaced to the server (empty when disabled)."
  value       = local.openai_endpoint
}

output "pro_license_enabled" {
  description = "Whether the server is configured to load a signed Pro license from Key Vault."
  value       = local.pro_license_enabled
}

output "pro_license_secret_id" {
  description = "ID of the Key Vault secret holding the signed Pro license envelope (null when enable_pro_license is false)."
  value       = try(azurerm_key_vault_secret.pro_license[0].id, null)
  sensitive   = true
}
