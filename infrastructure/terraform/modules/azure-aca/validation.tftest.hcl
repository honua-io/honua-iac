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

override_resource {
  target = azurerm_user_assigned_identity.this

  values = {
    client_id    = "00000000-0000-0000-0000-000000000005"
    principal_id = "00000000-0000-0000-0000-000000000006"
  }
}

variables {
  image          = "ghcr.io/honua-io/honua-server:test-aca"
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

run "container_cpu_must_be_valid" {
  command = plan

  variables {
    container_cpu = 5.0
  }

  expect_failures = [
    var.container_cpu,
  ]
}

run "container_memory_format_must_end_with_gi" {
  command = plan

  variables {
    container_memory = "1024"
  }

  expect_failures = [
    var.container_memory,
  ]
}

run "container_memory_valid_format" {
  command = plan

  variables {
    container_memory = "2Gi"
  }
}

run "key_vault_soft_delete_retention_too_low" {
  command = plan

  variables {
    key_vault_soft_delete_retention_days = 3
  }

  expect_failures = [
    var.key_vault_soft_delete_retention_days,
  ]
}

run "key_vault_soft_delete_retention_too_high" {
  command = plan

  variables {
    key_vault_soft_delete_retention_days = 91
  }

  expect_failures = [
    var.key_vault_soft_delete_retention_days,
  ]
}

# --- Control-plane output shape tests ---

run "control_plane_outputs_shape" {
  command = plan

  assert {
    condition     = output.control_plane_target_kind == "AzureContainerApps"
    error_message = "Expected target kind AzureContainerApps."
  }

  assert {
    condition     = output.control_plane_backend_name == "honua-gitops-azure-container-apps"
    error_message = "Expected backend name honua-gitops-azure-container-apps."
  }

  assert {
    condition     = output.control_plane_telemetry_policy == "honua-http"
    error_message = "Expected telemetry policy honua-http."
  }
}
