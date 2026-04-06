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

run "image_reference_requires_tag_or_digest" {
  command = plan

  variables {
    image = "ghcr.io/honua-io/honua-server"
  }

  expect_failures = [
    var.image,
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

run "container_port_must_be_valid" {
  command = plan

  variables {
    container_port = 0
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

run "scaling_concurrent_requests_must_be_valid" {
  command = plan

  variables {
    scaling_concurrent_requests = "0"
  }

  expect_failures = [
    var.scaling_concurrent_requests,
  ]
}

run "replica_bounds" {
  command = plan

  variables {
    min_replicas = 3
    max_replicas = 2
  }

  expect_failures = [
    check.replica_bounds,
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

run "ingress_requires_allowed_cidrs" {
  command = plan

  variables {
    enable_ingress = true
  }

  expect_failures = [
    check.ingress_requires_allowed_cidrs,
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

run "key_vault_diagnostics_requires_workspace" {
  command = plan

  variables {
    log_analytics_enabled = false
  }

  expect_failures = [
    check.key_vault_diagnostics_requires_workspace,
  ]
}

run "operations_metadata_exposes_key_vault_diagnostics" {
  command = plan

  assert {
    condition     = output.operations_metadata.secret_store.diagnostics.enabled == true
    error_message = "Expected Key Vault diagnostics to be enabled by default."
  }
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

  assert {
    condition     = output.control_plane_current_image == "ghcr.io/honua-io/honua-server:test-aca"
    error_message = "Expected the ACA image to surface through the unified control-plane outputs."
  }

  assert {
    condition     = output.marketplace_profile.eligible
    error_message = "Expected ACA to be classified as a marketplace-eligible runtime."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).target.kind == "AzureContainerApps"
    error_message = "Expected the unified control-plane contract to expose the ACA target kind."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).target_kind == "AzureContainerApps"
    error_message = "Expected the top-level deploy contract target_kind to match AzureContainerApps."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).artifact_reference.desired == "ghcr.io/honua-io/honua-server:test-aca"
    error_message = "Expected the top-level deploy contract to publish the ACA image as the desired artifact reference."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).secret_refs.database_connection.kind == "azure-key-vault-secret"
    error_message = "Expected the top-level deploy contract to expose the DB Key Vault secret kind."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).secret_refs.connection_encryption_master_key.kind == "azure-key-vault-secret"
    error_message = "Expected the top-level deploy contract to expose the connection encryption secret reference kind."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).health_policy.telemetry_policy == "honua-http"
    error_message = "Expected the top-level deploy contract to expose the honua-http telemetry policy."
  }

  assert {
    condition     = output.operations_metadata.database.port == 5432
    error_message = "Expected operations metadata to expose PostgreSQL port 5432."
  }

  assert {
    condition     = output.operations_metadata.database.postgis.readiness_max_attempts == 30
    error_message = "Expected operations metadata to expose the default PostGIS readiness attempts."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).marketplace.bundle_profile == "marketplace-turnkey"
    error_message = "Expected ACA to advertise the marketplace-turnkey bundle profile."
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
