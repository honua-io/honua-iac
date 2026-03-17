mock_provider "azurerm" {}

variables {
  honua_admin_password = "01234567890123456789012345678901"
}

override_module {
  target = module.data
  outputs = {
    db_fqdn                 = "honua-db.postgres.database.azure.com"
    db_connection_string    = "Host=honua-db.postgres.database.azure.com;Database=honua"
    redis_connection_string = "rediss://cache.example.test:6380"
    key_vault_id            = "/subscriptions/test/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/honua"
    key_vault_name          = "honua-kv"
    resource_group_name     = "rg-honua"
  }
}

run "azure_data_groups_operator_outputs" {
  command = plan

  assert {
    condition     = output.infrastructure_outputs.data.key_vault_name == "honua-kv"
    error_message = "azure-data should expose day-2 resource identifiers through infrastructure_outputs."
  }

  assert {
    condition     = output.resource_group_name == "rg-honua"
    error_message = "azure-data should preserve the legacy resource-group output."
  }
}
