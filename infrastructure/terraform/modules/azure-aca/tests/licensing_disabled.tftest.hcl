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
mock_provider "time" {
  mock_resource "time_static" {
    defaults = {
      rfc3339 = "2026-01-01T00:00:00Z"
    }
  }
}

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
    condition     = var.licensing_mode == "Disabled" && output.licensing_mode == "Disabled"
    error_message = "The default licensing mode must be Disabled."
  }

  assert {
    condition = length([
      for entry in azurerm_container_app.this.template[0].container[0].env : entry
      if entry.name == "Licensing__Mode" && entry.value == "Disabled"
    ]) == 1
    error_message = "The container must carry exactly one Licensing__Mode=Disabled environment entry."
  }
}

run "enabled_is_opt_in" {
  command = plan

  variables {
    licensing_mode = "Enabled"
  }

  assert {
    condition = length([
      for entry in azurerm_container_app.this.template[0].container[0].env : entry
      if entry.name == "Licensing__Mode" && entry.value == "Enabled"
    ]) == 1
    error_message = "An operator who opts into licensing must get Licensing__Mode=Enabled."
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
