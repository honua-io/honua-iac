mock_provider "azurerm" {}

variables {
  honua_image             = "ghcr.io/honua-io/honua-server:test"
  honua_admin_password    = "01234567890123456789012345678901"
  db_admin_password       = "example-db-password"
  deployment_slot_enabled = true
}

override_module {
  target = module.stack.module.honua
  outputs = {
    environment                         = "it"
    function_app_url                    = "https://honua-functions.example.test"
    function_app_name                   = "honua-fn"
    function_app_id                     = "/subscriptions/test/resourceGroups/rg/providers/Microsoft.Web/sites/honua-fn"
    control_plane_target_kind           = "azure-function-app"
    control_plane_backend_name          = "azure-functions"
    control_plane_target_id             = "it-honua-fn"
    control_plane_target_name           = "honua-fn"
    control_plane_target_resource_id    = "/subscriptions/test/resourceGroups/rg/providers/Microsoft.Web/sites/honua-fn"
    control_plane_target_resource_group = "rg-honua"
    control_plane_telemetry_policy      = "azure-monitor"
    control_plane_current_revision      = "production"
    control_plane_desired_revision      = "staging"
    control_plane_slot_name             = "staging"
    control_plane_current_image         = "ghcr.io/honua-io/honua-server:prod"
    control_plane_desired_image         = "ghcr.io/honua-io/honua-server:staging"
    function_app_slot_name              = "staging"
    function_app_slot_id                = "/subscriptions/test/resourceGroups/rg/providers/Microsoft.Web/sites/honua-fn/slots/staging"
    db_fqdn                             = "honua-db.postgres.database.azure.com"
    resource_group_name                 = "rg-honua"
  }
}

run "functions_outputs_and_contracts_stay_coherent" {
  command = plan

  assert {
    condition     = output.infrastructure_outputs.workload.slot_name == "staging"
    error_message = "azure-functions example should expose slot information through infrastructure_outputs."
  }

  assert {
    condition     = output.honua_integration_outputs.control_plane.desired_revision == "staging"
    error_message = "azure-functions example should preserve rollout revision metadata."
  }

  assert {
    condition     = output.validation_contract.platform.capabilities.deploy_plan == true
    error_message = "azure-functions validation contract should reflect slot-enabled deploy-plan support."
  }
}

run "rejects_invalid_plan_sku" {
  command = plan

  variables {
    plan_sku_name = "B1"
  }

  expect_failures = [var.plan_sku_name]
}
