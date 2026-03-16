mock_provider "aws" {}

variables {
  honua_image          = "ghcr.io/honua-io/honua-server:test"
  honua_admin_password = "01234567890123456789012345678901"
  db_password          = "example-db-password"
}

override_module {
  target = module.honua
  outputs = {
    service_url                                   = "https://honua-ecs.example.test"
    ecs_cluster_name                              = "honua-ecs-cluster"
    ecs_service_name                              = "honua-ecs-service"
    canary_enabled                                = true
    canary_ecs_service_name                       = "honua-ecs-canary"
    canary_verification_header_name               = "X-Honua-Canary"
    canary_verification_header_value              = "always"
    control_plane_target_kind                     = "ecs-service"
    control_plane_backend_name                    = "aws-ecs"
    control_plane_telemetry_policy                = "prometheus"
    control_plane_telemetry_prometheus_job        = "honua"
    control_plane_telemetry_prometheus_canary_job = "honua-canary"
    db_endpoint                                   = "honua-db.internal"
    redis_primary_endpoint                        = "honua-redis.internal"
  }
}

run "output_groups_are_split_for_customers_and_honua" {
  command = plan

  assert {
    condition     = output.infrastructure_outputs.endpoints.public_base_url == "https://honua-ecs.example.test"
    error_message = "aws example should expose the public URL through infrastructure_outputs."
  }

  assert {
    condition     = output.infrastructure_outputs.workload.cluster_name == "honua-ecs-cluster"
    error_message = "aws example should expose ECS workload details through infrastructure_outputs."
  }

  assert {
    condition     = output.honua_integration_outputs.control_plane.backend_name == "aws-ecs"
    error_message = "aws example should group Honua control-plane metadata separately."
  }

  assert {
    condition     = output.deployment_contract.stack.platform == "aws-ecs"
    error_message = "aws example should preserve the deployment contract output."
  }
}

run "rejects_invalid_canary_weight" {
  command = plan

  variables {
    canary_weight_percentage = 150
  }

  expect_failures = [var.canary_weight_percentage]
}
