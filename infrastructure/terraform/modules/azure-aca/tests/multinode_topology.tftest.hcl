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
  image          = "ghcr.io/honua-io/honua-server:v1.5.0"
  admin_password = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  existing_db_fqdn              = "postgres.example.internal"
  existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
  redis_enabled                 = false
}

run "single_instance_default_is_safe" {
  command = plan
}

run "reserved_runtime_env_cannot_bypass_typed_inputs" {
  command = plan

  variables {
    additional_env = {
      "FILESTORAGE:PROVIDER" = "Local"
    }
  }

  expect_failures = [var.additional_env]
}

run "single_instance_scale_out_is_rejected" {
  command = plan

  variables {
    max_replicas = 2
  }

  expect_failures = [azurerm_container_app.this]
}

run "multinode_without_shared_dependencies_is_rejected" {
  command = plan

  variables {
    deployment_mode = "MultiNode"
  }

  expect_failures = [azurerm_container_app.this]
}

run "multinode_scale_out_with_redis_and_blob_is_safe" {
  command = plan

  variables {
    min_replicas                              = 2
    max_replicas                              = 4
    deployment_mode                           = "MultiNode"
    redis_connection_string                   = "redis.example.internal:6380,password=test,ssl=true"
    file_storage_provider                     = "AzureBlob"
    file_storage_azure_blob_connection_string = "DefaultEndpointsProtocol=https;AccountName=honuastorage;AccountKey=test;EndpointSuffix=core.windows.net"
    file_storage_azure_blob_container_name    = "honua-test-files"
  }
}
