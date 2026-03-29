output "client_id" {
  value       = azuread_application.terraform.client_id
  description = "Client ID of the bootstrap Microsoft Entra application."
}

output "client_secret" {
  value       = try(azuread_service_principal_password.terraform[0].value, null)
  description = "Fallback client secret when create_client_secret is enabled."
  sensitive   = true
}

output "tenant_id" {
  value       = data.azurerm_client_config.current.tenant_id
  description = "Tenant ID hosting the bootstrap Microsoft Entra application."
}

output "subscription_id" {
  value       = data.azurerm_subscription.current.subscription_id
  description = "Subscription ID targeted by the bootstrap role definition."
}

output "scope" {
  value       = local.scope
  description = "Assignable scope for the custom Terraform role."
}

output "role_definition_id" {
  value       = azurerm_role_definition.terraform.role_definition_resource_id
  description = "Resource ID of the custom Terraform role definition."
}

output "federated_credential_id" {
  value       = try(azuread_application_federated_identity_credential.terraform[0].credential_id, null)
  description = "Credential ID for the optional workload identity federated credential."
}

output "client_secret_duration_hours" {
  value       = var.create_client_secret ? var.service_principal_secret_duration_hours : null
  description = "Rotation window for the fallback client secret when create_client_secret is enabled."
}

output "bootstrap_identity_contract" {
  description = "Structured contract describing the supported authentication surfaces for this bootstrap identity."
  value = {
    schema_version               = "v1"
    auth_mode                    = trimspace(var.federated_issuer) != "" && trimspace(var.federated_subject) != "" ? "workload_identity" : (var.create_client_secret ? "client_secret" : "application_only")
    client_id                    = azuread_application.terraform.client_id
    tenant_id                    = data.azurerm_client_config.current.tenant_id
    subscription_id              = data.azurerm_subscription.current.subscription_id
    scope                        = local.scope
    role_definition_id           = azurerm_role_definition.terraform.role_definition_resource_id
    federated_issuer             = trimspace(var.federated_issuer) != "" ? var.federated_issuer : null
    federated_subject            = trimspace(var.federated_subject) != "" ? var.federated_subject : null
    federated_audiences          = length(var.federated_audiences) > 0 ? var.federated_audiences : null
    federated_credential_id      = try(azuread_application_federated_identity_credential.terraform[0].credential_id, null)
    client_secret_duration_hours = var.create_client_secret ? var.service_principal_secret_duration_hours : null
  }
}
