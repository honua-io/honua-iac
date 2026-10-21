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
  image                            = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  connection_encryption_master_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  existing_db_fqdn              = "postgres.example.internal"
  existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
  redis_enabled                 = false
}

run "default_declares_licensing_disabled" {
  command = plan

  assert {
    condition     = local.licensing_mode == "Disabled" && output.licensing_mode == "Disabled"
    error_message = "The default licensing mode must be Disabled."
  }

  assert {
    condition     = azurerm_linux_function_app.this.app_settings["Licensing__Mode"] == "Disabled"
    error_message = "The Function App must carry Licensing__Mode=Disabled."
  }

  assert {
    condition     = length(azurerm_key_vault_secret.pro_license) == 0
    error_message = "The default deployment must not create a Pro license secret."
  }
}

run "enabled_without_an_envelope_is_opt_in" {
  command = plan

  variables {
    licensing_mode = "Enabled"
  }

  assert {
    condition     = local.licensing_mode == "Enabled" && azurerm_linux_function_app.this.app_settings["Licensing__Mode"] == "Enabled"
    error_message = "An operator who opts into licensing must get Licensing__Mode=Enabled."
  }
}

run "pro_license_forces_enabled" {
  command = plan

  variables {
    licensing_mode                 = "Disabled"
    enable_pro_license             = true
    pro_license_content            = "{\"keyId\":\"honuademo2026q2\"}"
    pro_license_trusted_public_key = "base64url:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  }

  assert {
    condition     = local.licensing_mode == "Enabled" && azurerm_linux_function_app.this.app_settings["Licensing__Mode"] == "Enabled"
    error_message = "enable_pro_license must force Licensing__Mode=Enabled."
  }

  assert {
    condition     = length(azurerm_key_vault_secret.pro_license) == 1
    error_message = "enable_pro_license must store the envelope in Key Vault."
  }
}

run "licensing_mode_is_not_overridable_through_additional_env" {
  command = plan

  variables {
    additional_env = {
      "Licensing:Mode" = "Enabled"
    }
  }

  expect_failures = [var.additional_env]
}

run "a_non_server_licensing_mode_is_rejected" {
  command = plan

  variables {
    licensing_mode = "Community"
  }

  expect_failures = [var.licensing_mode]
}
