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

run "node_pool_scaling_bounds" {
  command = plan

  variables {
    auto_scaling_enabled = true
    node_min_count       = 4
    node_max_count       = 3
  }

  expect_failures = [
    check.node_pool_scaling_bounds,
  ]
}

run "authorized_ip_ranges_must_be_cidr" {
  command = plan

  variables {
    authorized_ip_ranges = ["203.0.113.10"]
  }

  expect_failures = [
    var.authorized_ip_ranges,
  ]
}

run "public_api_requires_authorized_ip_ranges" {
  command = plan

  variables {
    private_cluster_enabled = false
  }

  expect_failures = [
    check.public_api_requires_authorized_ip_ranges,
  ]
}

run "local_account_disable_requires_managed_aad" {
  command = plan

  variables {
    local_account_disabled = true
    managed_aad_enabled    = false
  }

  expect_failures = [
    check.local_account_disable_requires_managed_aad,
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
