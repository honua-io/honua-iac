mock_provider "azurerm" {}
mock_provider "random" {}
mock_provider "null" {}
mock_provider "time" {}

override_data {
  target = data.azurerm_client_config.current

  values = {
    client_id       = "00000000-0000-0000-0000-000000000011"
    object_id       = "00000000-0000-0000-0000-000000000012"
    subscription_id = "00000000-0000-0000-0000-000000000013"
    tenant_id       = "00000000-0000-0000-0000-000000000014"
  }
}

override_resource {
  target = azurerm_user_assigned_identity.function

  values = {
    client_id    = "00000000-0000-0000-0000-000000000015"
    principal_id = "00000000-0000-0000-0000-000000000016"
  }
}

variables {
  image          = "ghcr.io/honua-io/honua-server:test-functions"
  admin_password = "test-password-that-is-at-least-32-chars!"
}

# --- Variable validation tests ---

run "admin_password_minimum_length" {
  command = plan

  variables {
    admin_password = "short"
  }

  expect_failures = [
    var.admin_password,
  ]
}

run "postgis_readiness_max_attempts_minimum" {
  command = plan

  variables {
    postgis_readiness_max_attempts = 0
  }

  expect_failures = [
    var.postgis_readiness_max_attempts,
  ]
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

# --- Control-plane output shape tests ---

run "control_plane_outputs_without_slot" {
  command = plan

  variables {
    deployment_slot_enabled = false
  }

  assert {
    condition     = output.control_plane_target_kind == "AzureFunctions"
    error_message = "Expected target kind AzureFunctions."
  }

  assert {
    condition     = output.control_plane_backend_name == "honua-gitops-azure-functions"
    error_message = "Expected backend name honua-gitops-azure-functions."
  }

  assert {
    condition     = output.control_plane_telemetry_policy == "honua-http"
    error_message = "Expected telemetry policy honua-http."
  }

  assert {
    condition     = output.control_plane_current_revision == null
    error_message = "Expected null current revision when slots are disabled."
  }

  assert {
    condition     = output.control_plane_desired_revision == null
    error_message = "Expected null desired revision when slots are disabled."
  }

  assert {
    condition     = output.control_plane_slot_name == null
    error_message = "Expected null slot name when slots are disabled."
  }

  assert {
    condition     = output.function_app_slot_name == null
    error_message = "Expected null slot name when slots are disabled."
  }

  assert {
    condition     = output.operations_metadata.database.port == 5432
    error_message = "Expected operations metadata to expose PostgreSQL port 5432."
  }
}

run "control_plane_outputs_with_slot" {
  command = plan

  variables {
    deployment_slot_enabled = true
    deployment_slot_name    = "staging"
    deployment_slot_image   = "ghcr.io/honua-io/honua-server:test-functions-staging"
  }

  assert {
    condition     = output.control_plane_current_revision == "production"
    error_message = "Expected current revision to be 'production' when slots are enabled."
  }

  assert {
    condition     = output.control_plane_desired_revision == "staging"
    error_message = "Expected desired revision to match slot name."
  }

  assert {
    condition     = output.operations_metadata.workload.deployment_slot_enabled
    error_message = "Expected operations metadata to note slot-based rollout mode."
  }
}
