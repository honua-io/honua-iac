# Allowlist for request-supplied secret references (honua-server #5055).
#
# The server section Security:RequestSecretReferences is deny-by-default, so the
# module must render NOTHING unless an operator supplies entries, and must render
# supplied entries as indexed variables in list order. The expected names are the
# server's published contract (docs/guides/deploy/configuration.md), not a
# snapshot of this module's output.

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
  image                            = "ghcr.io/honua-io/honua-server:v1.5.0"
  admin_password                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  connection_encryption_master_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  existing_db_fqdn              = "postgres.example.internal"
  existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
  redis_enabled                 = false
}

run "no_allowlist_entry_is_rendered_by_default" {
  command = plan

  assert {
    condition = length([
      for entry in azurerm_container_app.this.template[0].container[0].env :
      entry if startswith(entry.name, "Security__RequestSecretReferences__")
    ]) == 0
    error_message = "With no entries supplied the container must carry no allowlist variable, preserving deny-by-default."
  }
}

run "entries_render_as_indexed_variables_in_list_order" {
  command = plan

  variables {
    request_secret_reference_allowed_environment_variables         = ["HONUA_IMPORT_ARCGIS_TOKEN"]
    request_secret_reference_allowed_environment_variable_prefixes = ["HONUA_IMPORT_"]
    request_secret_reference_allowed_secret_reference_prefixes     = ["azure:keyvault:honua-imports:", "azure:keyvault:honua-connections:"]
  }

  assert {
    condition = {
      for entry in azurerm_container_app.this.template[0].container[0].env :
      entry.name => entry.value if startswith(entry.name, "Security__RequestSecretReferences__")
      } == {
      Security__RequestSecretReferences__AllowedEnvironmentVariables__0        = "HONUA_IMPORT_ARCGIS_TOKEN"
      Security__RequestSecretReferences__AllowedEnvironmentVariablePrefixes__0 = "HONUA_IMPORT_"
      # checkov:skip=CKV_SECRET_6: Configuration key names and placeholder reference prefixes, not credentials.
      Security__RequestSecretReferences__AllowedSecretReferencePrefixes__0 = "azure:keyvault:honua-imports:"
      # checkov:skip=CKV_SECRET_6: Configuration key names and placeholder reference prefixes, not credentials.
      Security__RequestSecretReferences__AllowedSecretReferencePrefixes__1 = "azure:keyvault:honua-connections:"
    }
    error_message = "The container must carry exactly the supplied entries under the server's indexed variable names."
  }
}

run "an_environment_reference_is_rejected_as_a_whole_reference_prefix" {
  command = plan

  variables {
    request_secret_reference_allowed_secret_reference_prefixes = ["env:HONUA_ADMIN_PASSWORD"]
  }

  expect_failures = [var.request_secret_reference_allowed_secret_reference_prefixes]
}

run "a_prefix_without_a_provider_segment_is_rejected" {
  command = plan

  variables {
    request_secret_reference_allowed_secret_reference_prefixes = ["honua/imports/"]
  }

  expect_failures = [var.request_secret_reference_allowed_secret_reference_prefixes]
}

run "an_invalid_environment_variable_name_is_rejected" {
  command = plan

  variables {
    request_secret_reference_allowed_environment_variables = ["NOT-A-NAME"]
  }

  expect_failures = [var.request_secret_reference_allowed_environment_variables]
}

run "an_invalid_environment_variable_prefix_is_rejected" {
  command = plan

  variables {
    request_secret_reference_allowed_environment_variable_prefixes = ["env:HONUA_"]
  }

  expect_failures = [var.request_secret_reference_allowed_environment_variable_prefixes]
}
