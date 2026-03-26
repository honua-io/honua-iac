mock_provider "aws" {}
mock_provider "random" {}
mock_provider "null" {}

override_data {
  target = data.aws_availability_zones.available

  values = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

override_data {
  target = data.aws_iam_policy_document.ecs_task_assume

  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

override_data {
  target = data.aws_iam_policy_document.kms

  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

variables {
  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua:test"
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
    image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua"
  }

  expect_failures = [
    var.image,
  ]
}

run "canary_weight_must_be_0_to_100" {
  command = plan

  variables {
    canary_weight_percentage = 101
  }

  expect_failures = [
    var.canary_weight_percentage,
  ]
}

run "canary_header_name_required" {
  command = plan

  variables {
    canary_enabled     = true
    canary_header_name = ""
  }

  expect_failures = [
    var.canary_header_name,
  ]
}

run "canary_header_value_required" {
  command = plan

  variables {
    canary_enabled      = true
    canary_header_value = ""
  }

  expect_failures = [
    var.canary_header_value,
  ]
}

run "task_cpu_architecture_must_be_valid" {
  command = plan

  variables {
    task_cpu_architecture = "RISC-V"
  }

  expect_failures = [
    var.task_cpu_architecture,
  ]
}

run "container_port_must_be_valid" {
  command = plan

  variables {
    container_port = 70000
  }

  expect_failures = [
    var.container_port,
  ]
}

run "app_storage_prefix_must_not_start_with_slash" {
  command = plan

  variables {
    app_storage_prefix = "/validation"
  }

  expect_failures = [
    var.app_storage_prefix,
  ]
}

run "autoscaling_cpu_target_value_must_be_valid" {
  command = plan

  variables {
    autoscaling_cpu_target_value = 0
  }

  expect_failures = [
    var.autoscaling_cpu_target_value,
  ]
}

run "health_check_path_must_start_with_slash" {
  command = plan

  variables {
    health_check_path = "healthz/ready"
  }

  expect_failures = [
    var.health_check_path,
  ]
}

run "existing_db_reuse_requires_cidrs" {
  command = plan

  variables {
    existing_db_endpoint          = "db.example.internal"
    existing_db_connection_string = "Host=db.example.internal;Port=5432;Database=honua;Username=honua;Password=test-password-that-is-at-least-32-chars!;SSL Mode=Require"
    existing_db_cidrs             = []
    enable_postgis                = false
  }

  expect_failures = [
    check.existing_db_reuse_requires_cidrs,
  ]
}

run "redis_reuse_is_exclusive" {
  command = plan

  variables {
    redis_enabled           = true
    redis_connection_string = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs  = ["10.0.0.0/16"]
  }

  expect_failures = [
    check.redis_reuse_is_exclusive,
  ]
}

run "redis_auth_token_rejects_unsupported_special_characters" {
  command = plan

  variables {
    redis_auth_token = "invalid-redis-token.with-dot"
  }

  expect_failures = [
    var.redis_auth_token,
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

run "canary_listener_rule_priority_bounds" {
  command = plan

  variables {
    canary_listener_rule_priority = 50001
  }

  expect_failures = [
    var.canary_listener_rule_priority,
  ]
}

run "ecs_scaling_bounds" {
  command = plan

  variables {
    desired_count = 5
    min_capacity  = 1
    max_capacity  = 4
  }

  expect_failures = [
    check.ecs_scaling_bounds,
  ]
}

# --- Control-plane output shape tests ---

run "control_plane_outputs_without_canary" {
  command = plan

  variables {
    canary_enabled = false
  }

  assert {
    condition     = output.control_plane_target_kind == "AwsEcs"
    error_message = "Expected target kind AwsEcs."
  }

  assert {
    condition     = output.control_plane_backend_name == "honua-gitops-aws-ecs"
    error_message = "Expected backend name honua-gitops-aws-ecs."
  }

  assert {
    condition     = output.control_plane_telemetry_policy == "honua-http"
    error_message = "Expected telemetry policy honua-http when canary is disabled."
  }

  assert {
    condition     = output.control_plane_telemetry_prometheus_canary_job == null
    error_message = "Expected null canary Prometheus job when canary is disabled."
  }

  assert {
    condition     = output.control_plane_target_id == "honua-dev-cluster/honua-dev-service"
    error_message = "Expected a stable ECS target id composed from cluster and service name."
  }

  assert {
    condition     = output.control_plane_current_image == "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua:test"
    error_message = "Expected the stable ECS image to surface through the unified control-plane outputs."
  }

  assert {
    condition     = output.marketplace_profile.eligible
    error_message = "Expected ECS to be classified as a marketplace-eligible runtime."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).target.kind == "AwsEcs"
    error_message = "Expected the unified control-plane contract to expose the ECS target kind."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).target_kind == "AwsEcs"
    error_message = "Expected the top-level deploy contract target_kind to match AwsEcs."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).artifact_reference.desired == "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua:test"
    error_message = "Expected the top-level desired artifact reference to match the primary ECS image."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).secret_refs.database_connection.kind == "aws-secrets-manager"
    error_message = "Expected the top-level deploy contract to expose the DB secret reference kind."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).secret_refs.connection_encryption_master_key.kind == "aws-secrets-manager"
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
}

run "control_plane_outputs_with_canary" {
  command = plan

  variables {
    canary_enabled = true
    canary_image   = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua:canary"
  }

  assert {
    condition     = output.control_plane_telemetry_policy == "aws-alb-canary"
    error_message = "Expected telemetry policy aws-alb-canary when canary is enabled."
  }

  assert {
    condition     = output.control_plane_telemetry_prometheus_canary_job == "honua-canary"
    error_message = "Expected canary Prometheus job honua-canary when canary is enabled."
  }

  assert {
    condition     = output.operations_metadata.workload.canary_service_name != null
    error_message = "Expected canary operations metadata when canary is enabled."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).rollout.progressive_delivery
    error_message = "Expected the unified control-plane contract to flag ECS canary rollouts."
  }

  assert {
    condition     = nonsensitive(output.control_plane_contract).artifact_reference.desired == "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua:canary"
    error_message = "Expected canary rollouts to publish the canary image as the desired artifact reference."
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
    condition     = output.operations_metadata.object_storage.kind == "s3"
    error_message = "Expected operations metadata to expose S3 object storage."
  }
}
