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

variables {
  image                            = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  connection_encryption_master_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  redis_enabled                    = false
}

run "unbounded_instances_keep_the_server_default" {
  command = plan

  assert {
    condition = (
      output.db_connection_budget.source == "server-default" &&
      !contains(keys(azurerm_linux_function_app.this.app_settings), "Limits__Connections__MaxConnectionPoolSize")
    )
    error_message = "Without functions_max_instances the instance count is unknown, so no pool keys are rendered."
  }
}

# B_Standard_B2s: 429, 414 usable, floor(351.9) = 351 / (8 instances x 2 pools) = 21.
run "bounded_instances_are_sized_and_limited" {
  command = plan

  variables {
    db_sku_name             = "B_Standard_B2s"
    functions_max_instances = 8
  }

  assert {
    condition = (
      output.db_connection_budget.pool_size == 21 &&
      azurerm_linux_function_app.this.app_settings["Limits__Connections__MaxConnectionPoolSize"] == "21" &&
      azurerm_linux_function_app.this.app_settings["Limits__Connections__MaxConcurrentQueries"] == "21" &&
      azurerm_linux_function_app.this.app_settings["Limits__Connections__MinConnectionPoolSize"] == "0" &&
      azurerm_linux_function_app.this.site_config[0].app_scale_limit == 8
    )
    error_message = "functions_max_instances must size the pools (MinConnectionPoolSize 0) and set the app scale limit."
  }
}

run "staging_slot_doubles_the_processes" {
  command = plan

  variables {
    db_sku_name             = "B_Standard_B2s"
    functions_max_instances = 8
    deployment_slot_enabled = true
  }

  assert {
    condition     = output.db_connection_budget.max_processes == 16 && output.db_connection_budget.pool_size == 10
    error_message = "The staging slot runs its own instances and must be counted."
  }
}

# Default B1ms (35 usable) cannot hold 20 instances x 2 pools even at 1.
run "infeasible_instance_ceiling_fails_plan" {
  command = plan

  variables {
    functions_max_instances = 20
  }

  expect_failures = [output.db_connection_budget]
}
