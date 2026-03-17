mock_provider "azurerm" {}

variables {
  honua_image          = "ghcr.io/honua-io/honua-server:test"
  honua_admin_password = "01234567890123456789012345678901"
  db_admin_password    = "example-db-password"
}

override_module {
  target = module.honua
  outputs = {
    environment                         = "it"
    container_app_fqdn                  = "https://honua-aca.example.test"
    container_app_name                  = "honua-aca"
    container_app_id                    = "/subscriptions/test/resourceGroups/rg/providers/Microsoft.App/containerApps/honua-aca"
    container_app_environment_id        = "/subscriptions/test/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/honua"
    control_plane_target_kind           = "azure-container-app"
    control_plane_backend_name          = "azure-aca"
    control_plane_target_id             = "it-honua-aca"
    control_plane_target_name           = "honua-aca"
    control_plane_target_resource_id    = "/subscriptions/test/resourceGroups/rg/providers/Microsoft.App/containerApps/honua-aca"
    control_plane_target_resource_group = "rg-honua"
    control_plane_telemetry_policy      = "azure-monitor"
    database_fqdn                       = "honua-db.postgres.database.azure.com"
    resource_group_name                 = "rg-honua"
  }
}

run "azure_container_outputs_are_grouped" {
  command = plan

  assert {
    condition     = output.infrastructure_outputs.workload.container_app_name == "honua-aca"
    error_message = "azure example should expose container app details through infrastructure_outputs."
  }

  assert {
    condition     = output.honua_integration_outputs.control_plane.target_resource_group == "rg-honua"
    error_message = "azure example should group Honua resource metadata separately."
  }

  assert {
    condition     = output.operations_contract.grouping.resource_group == "rg-honua"
    error_message = "azure example should keep the operations contract intact."
  }
}
