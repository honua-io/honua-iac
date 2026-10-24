# Database pool sizing (db-pool-sizing.tf; README: Database connection sizing).
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
  redis_enabled                    = false
}

# B_Standard_B1ms: 50 max_connections, 35 usable after 15 reserved,
# floor(35 x 0.85) = 29, / (1 replica x 2 for the Single-revision rollover
# x 2 pools) = 7.
run "default_sku_is_sized" {
  command = plan

  assert {
    condition = (
      output.db_connection_budget.max_connections == 50 &&
      output.db_connection_budget.usable_connections == 35 &&
      output.db_connection_budget.max_processes == 2 &&
      output.db_connection_budget.pool_size == 7
    )
    error_message = "The default B1ms server with one replica must derive a pool of 7."
  }

  assert {
    condition = {
      for entry in azurerm_container_app.this.template[0].container[0].env :
      entry.name => entry.value if startswith(entry.name, "Limits__Connections__")
      } == {
      Limits__Connections__MaxConnectionPoolSize = "7"
      Limits__Connections__MaxConcurrentQueries  = "7"
      Limits__Connections__MinConnectionPoolSize = "7"
    }
    error_message = "The container must carry the derived pool keys."
  }
}

# GP_Standard_D4ds_v5: 1718, 1703 usable, floor(1447.55) = 1447 / (10 x 2 x 2) = 36.
run "general_purpose_sku_scales_with_max_replicas" {
  command = plan

  variables {
    db_sku_name                               = "GP_Standard_D4ds_v5"
    min_replicas                              = 2
    max_replicas                              = 10
    deployment_mode                           = "MultiNode"
    redis_connection_string                   = "redis.example.internal:6380,password=test,ssl=true"
    file_storage_provider                     = "AzureBlob"
    file_storage_azure_blob_connection_string = "DefaultEndpointsProtocol=https;AccountName=honuastorage;AccountKey=test;EndpointSuffix=core.windows.net"
    file_storage_azure_blob_container_name    = "honua-test-files"
  }

  assert {
    condition     = output.db_connection_budget.max_connections == 1718 && output.db_connection_budget.pool_size == 36
    error_message = "A D4 server with 10 replicas must derive a pool of 36."
  }
}

run "additional_env_wins_without_duplicate_names" {
  command = plan

  variables {
    additional_env = {
      Limits__Connections__MaxConnectionPoolSize = "4"
      Limits__Connections__MaxConcurrentQueries  = "4"
    }
  }

  assert {
    condition = length([
      for entry in azurerm_container_app.this.template[0].container[0].env : entry
      if entry.name == "Limits__Connections__MaxConnectionPoolSize"
      ]) == 1 && one([
      for entry in azurerm_container_app.this.template[0].container[0].env : entry.value
      if entry.name == "Limits__Connections__MaxConnectionPoolSize"
    ]) == "4"
    error_message = "A hand-set additional_env pool key must win and appear once."
  }
}

run "oversized_override_fails_plan" {
  command = plan

  variables {
    db_pool_size_override = 10
  }

  # 2 x 2 x 10 = 40 > 35 usable.
  expect_failures = [output.db_connection_budget]
}

run "existing_database_keeps_the_server_default" {
  command = plan

  variables {
    existing_db_fqdn              = "postgres.example.internal"
    existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
  }

  assert {
    condition = output.db_connection_budget.source == "server-default" && length([
      for entry in azurerm_container_app.this.template[0].container[0].env : entry
      if startswith(entry.name, "Limits__Connections__")
    ]) == 0
    error_message = "With an existing server and no db_max_connections_override the module must not guess."
  }
}
