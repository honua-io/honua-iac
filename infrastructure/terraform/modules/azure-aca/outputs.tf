output "environment" {
  description = "Deployment environment label used for control-plane target IDs."
  value       = var.environment
}

output "container_app_name" {
  description = "Container App name."
  value       = azurerm_container_app.this.name
}

output "container_app_id" {
  description = "Container App resource ID."
  value       = azurerm_container_app.this.id
}

output "container_app_environment_id" {
  description = "Container Apps environment resource ID."
  value       = azurerm_container_app_environment.this.id
}

output "resource_group_name" {
  description = "Resource group name."
  value       = azurerm_resource_group.this.name
}

output "control_plane_target_kind" {
  description = "Honua control-plane deploy target kind for Azure Container Apps."
  value       = "AzureContainerApps"
}

output "control_plane_backend_name" {
  description = "Honua control-plane deploy backend name for Azure Container Apps GitOps."
  value       = "honua-gitops-azure-container-apps"
}

output "control_plane_target_id" {
  description = "Stable target id for Honua control-plane deploy operations."
  value       = azurerm_container_app.this.name
}

output "control_plane_target_name" {
  description = "Primary workload name used by the Honua deploy target."
  value       = azurerm_container_app.this.name
}

output "control_plane_target_resource_id" {
  description = "Stable Azure resource ID for the Honua deploy target."
  value       = azurerm_container_app.this.id
}

output "control_plane_target_resource_group" {
  description = "Stable Azure resource group for the Honua deploy target."
  value       = azurerm_resource_group.this.name
}

output "control_plane_telemetry_policy" {
  description = "Default Honua telemetry policy for Azure Container Apps deploy health evaluation."
  value       = "honua-http"
}

output "container_app_fqdn" {
  description = "Container App FQDN (if ingress enabled)."
  value       = try(azurerm_container_app.this.ingress[0].fqdn, null)
}

output "database_fqdn" {
  description = "PostgreSQL server FQDN."
  value       = local.db_server_fqdn
  sensitive   = true
}

output "key_vault_id" {
  description = "Key Vault resource ID."
  value       = azurerm_key_vault.this.id
}

output "db_connection_secret_id" {
  description = "Key Vault secret ID for the DB connection string."
  value       = azurerm_key_vault_secret.db_connection.id
}

output "admin_password_secret_id" {
  description = "Key Vault secret ID for the admin password."
  value       = azurerm_key_vault_secret.admin_password.id
}

output "connection_encryption_master_key_secret_id" {
  description = "Key Vault secret ID for the independent connection-encryption master key."
  value       = azurerm_key_vault_secret.master_key.id
}

output "redis_connection_secret_id" {
  description = "Key Vault secret ID for the Redis connection string (if set)."
  value       = local.redis_connection != "" ? azurerm_key_vault_secret.redis_connection[0].id : null
  sensitive   = true
}
