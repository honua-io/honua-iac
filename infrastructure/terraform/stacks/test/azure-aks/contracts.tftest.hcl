mock_provider "azurerm" {}

override_module {
  target = module.aks
  outputs = {
    resource_group_name            = "rg-honua"
    environment                    = "dev"
    cluster_name                   = "honua-aks"
    cluster_id                     = "/subscriptions/test/resourceGroups/rg-honua/providers/Microsoft.ContainerService/managedClusters/honua-aks"
    control_plane_target_kind      = "azure-aks-cluster"
    control_plane_backend_name     = "azure-aks"
    control_plane_telemetry_policy = "azure-monitor"
    honua_metrics_target           = "honua.monitoring.svc.cluster.local:8080"
  }
}

run "aks_outputs_are_split_by_audience" {
  command = plan

  assert {
    condition     = output.infrastructure_outputs.cluster.resource_group_name == "rg-honua"
    error_message = "azure-aks should expose resource-group details through infrastructure_outputs."
  }

  assert {
    condition     = output.honua_integration_outputs.control_plane.target_kind == "azure-aks-cluster"
    error_message = "azure-aks should isolate Honua metadata in honua_integration_outputs."
  }
}
