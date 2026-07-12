mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      client_id       = "00000000-0000-0000-0000-000000000001"
      object_id       = "00000000-0000-0000-0000-000000000002"
      subscription_id = "00000000-0000-0000-0000-000000000003"
      tenant_id       = "00000000-0000-0000-0000-000000000004"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  image                            = "ghcr.io/honua-io/honua-server:v1.5.0"
  admin_password                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  connection_encryption_master_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  existing_db_fqdn              = "postgres.example.internal"
  existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
  redis_enabled                 = false
}

run "connection_encryption_key_is_independent" {
  command = plan

  assert {
    condition     = azurerm_key_vault_secret.master_key.value == var.connection_encryption_master_key
    error_message = "The connection encryption secret must contain the independent master key."
  }

  assert {
    condition     = azurerm_key_vault_secret.master_key.value != azurerm_key_vault_secret.admin_password.value
    error_message = "The connection encryption key must not alias the admin password."
  }
}

run "connection_encryption_key_is_generated_when_unset" {
  command = plan

  variables {
    connection_encryption_master_key = null
  }

  assert {
    condition     = length(random_password.master_key) == 1
    error_message = "An independent connection encryption key must be generated when no key is provided."
  }
}
