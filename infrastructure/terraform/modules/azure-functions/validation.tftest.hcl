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

run "image_reference_requires_tag_or_digest" {
  command = plan

  variables {
    image = "ghcr.io/honua-io/honua-server"
  }

  expect_failures = [
    var.image,
  ]
}

run "container_port_must_be_valid" {
  command = plan

  variables {
    container_port = 70000
  }

  expect_failures = [
    var.container_port,
  ]
}

run "app_storage_container_name_must_be_valid" {
  command = plan

  variables {
    app_storage_container_name = "Invalid"
  }

  expect_failures = [
    var.app_storage_container_name,
  ]
}

run "deployment_slot_name_required" {
  command = plan

  variables {
    deployment_slot_enabled = true
    deployment_slot_name    = ""
  }

  expect_failures = [
    var.deployment_slot_name,
  ]
}

run "db_public_access_requires_firewall_rule" {
  command = plan

  variables {
    db_public_network_access = true
  }

  expect_failures = [
    check.db_public_access_requires_firewall_rule,
  ]
}

run "redis_reuse_is_exclusive" {
  command = plan

  variables {
    redis_enabled           = true
    redis_connection_string = "redis.example.internal:6380,password=test,ssl=true"
  }

  expect_failures = [
    check.redis_reuse_is_exclusive,
  ]
}

run "public_access_requires_ip_restriction" {
  command = plan

  variables {
    public_network_access_enabled = true
  }

  expect_failures = [
    check.public_access_requires_ip_restriction,
  ]
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
    condition     = output.control_plane_desired_image == "ghcr.io/honua-io/honua-server:test-functions"
    error_message = "Expected the desired image to fall back to the primary image when slots are disabled."
  }

  assert {
    condition     = !output.marketplace_profile.eligible
    error_message = "Expected Azure Functions to be excluded from marketplace-targeted bundles."
  }

  assert {
    condition     = output.function_app_slot_name == null
    error_message = "Expected null slot name when slots are disabled."
  }

  assert {
    condition     = output.operations_metadata.database.port == 5432
    error_message = "Expected operations metadata to expose PostgreSQL port 5432."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).target.kind == "AzureFunctions"
    error_message = "Expected the unified control-plane contract to expose the Azure Functions target kind."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).target_kind == "AzureFunctions"
    error_message = "Expected the top-level deploy contract target_kind to match AzureFunctions."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).secret_refs.database_connection.kind == "azure-key-vault-secret"
    error_message = "Expected the top-level deploy contract to expose the DB Key Vault secret kind."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).secret_refs.connection_encryption_master_key.kind == "azure-key-vault-secret"
    error_message = "Expected the top-level deploy contract to expose the connection encryption Key Vault secret kind."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).health_policy.telemetry_policy == "honua-http"
    error_message = "Expected the top-level deploy contract to expose the honua-http telemetry policy."
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

  assert {
    condition     = nonsensitive(output.control_plane_contract).artifact.desired == "ghcr.io/honua-io/honua-server:test-functions-staging"
    error_message = "Expected the unified control-plane contract to expose the slot image as the desired artifact."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).artifact_reference.desired == "ghcr.io/honua-io/honua-server:test-functions-staging"
    error_message = "Expected the top-level desired artifact reference to expose the slot image."
  }
}

run "app_storage_outputs_shape" {
  command = plan

  variables {
    app_storage_enabled = true
  }

  assert {
    condition     = output.app_storage_enabled
    error_message = "Expected application storage to be enabled."
  }

  assert {
    condition     = output.operations_metadata.object_storage.kind == "azure-blob"
    error_message = "Expected operations metadata to expose Azure Blob storage."
  }
}
