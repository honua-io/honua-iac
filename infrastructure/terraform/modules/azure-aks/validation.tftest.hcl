mock_provider "azurerm" {}

run "sku_tier_must_be_valid" {
  command = plan

  variables {
    sku_tier = "Enterprise"
  }

  expect_failures = [
    var.sku_tier,
  ]
}

run "control_plane_outputs_shape" {
  command = plan

  assert {
    condition     = output.control_plane_target_kind == "Kubernetes"
    error_message = "Expected target kind Kubernetes."
  }

  assert {
    condition     = output.control_plane_backend_name == "honua-gitops-kubernetes"
    error_message = "Expected backend name honua-gitops-kubernetes."
  }

  assert {
    condition     = output.honua_metrics_target == "honua"
    error_message = "Expected the default Honua metrics target hint."
  }
}
