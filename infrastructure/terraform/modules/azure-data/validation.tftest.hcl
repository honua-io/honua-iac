mock_provider "azurerm" {}
mock_provider "random" {}
mock_provider "null" {}
mock_provider "time" {}

override_data {
  target = data.azurerm_client_config.current

  values = {
    client_id       = "00000000-0000-0000-0000-000000000001"
    object_id       = "00000000-0000-0000-0000-000000000002"
    subscription_id = "00000000-0000-0000-0000-000000000003"
    tenant_id       = "00000000-0000-0000-0000-000000000004"
  }
}

variables {
  admin_password = "test-password-that-is-at-least-32-chars!"
}

run "postgis_readiness_sleep_seconds_minimum" {
  command = plan

  variables {
    postgis_readiness_sleep_seconds = 0
  }

  expect_failures = [
    var.postgis_readiness_sleep_seconds,
  ]
}

run "operations_metadata_shape" {
  command = plan

  assert {
    condition     = output.operations_metadata.database.port == 5432
    error_message = "Expected operations metadata to expose PostgreSQL port 5432."
  }

  assert {
    condition     = output.operations_metadata.database.backup_retention_days == 14
    error_message = "Expected the default Azure PostgreSQL backup retention to be 14 days."
  }

  assert {
    condition     = output.operations_metadata.cache.enabled == true
    error_message = "Expected Redis metadata to be enabled by default."
  }
}
