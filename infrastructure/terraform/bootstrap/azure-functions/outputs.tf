output "client_id" {
  value = azuread_application.terraform.client_id
}

output "client_secret" {
  value     = try(azuread_service_principal_password.terraform[0].value, null)
  sensitive = true
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  value = data.azurerm_subscription.current.subscription_id
}

output "scope" {
  value = local.scope
}

output "role_definition_id" {
  value = azurerm_role_definition.terraform.role_definition_resource_id
}

output "federated_credential_id" {
  value = try(azuread_application_federated_identity_credential.terraform[0].credential_id, null)
}

output "bootstrap_identity_contract" {
  value = {
    schema_version          = "v1"
    auth_mode               = trimspace(var.federated_issuer) != "" && trimspace(var.federated_subject) != "" ? "workload_identity" : (var.create_client_secret ? "client_secret" : "application_only")
    client_id               = azuread_application.terraform.client_id
    tenant_id               = data.azurerm_client_config.current.tenant_id
    subscription_id         = data.azurerm_subscription.current.subscription_id
    scope                   = local.scope
    role_definition_id      = azurerm_role_definition.terraform.role_definition_resource_id
    federated_issuer        = trimspace(var.federated_issuer) != "" ? var.federated_issuer : null
    federated_subject       = trimspace(var.federated_subject) != "" ? var.federated_subject : null
    federated_audiences     = length(var.federated_audiences) > 0 ? var.federated_audiences : null
    federated_credential_id = try(azuread_application_federated_identity_credential.terraform[0].credential_id, null)
  }
}
