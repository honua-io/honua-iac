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
}
