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
  target = data.aws_iam_policy_document.lambda_assume

  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

variables {
  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua:test-lambda"
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

run "lambda_timeout_too_low" {
  command = plan

  variables {
    lambda_timeout_seconds = 5
  }

  expect_failures = [
    var.lambda_timeout_seconds,
  ]
}

run "lambda_timeout_too_high" {
  command = plan

  variables {
    lambda_timeout_seconds = 901
  }

  expect_failures = [
    var.lambda_timeout_seconds,
  ]
}

run "lambda_alias_version_rejects_latest" {
  command = plan

  variables {
    lambda_alias_version = "$LATEST"
  }

  expect_failures = [
    var.lambda_alias_version,
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

# --- Control-plane output shape tests ---

run "control_plane_outputs_shape" {
  command = plan

  assert {
    condition     = output.control_plane_target_kind == "AwsLambda"
    error_message = "Expected target kind AwsLambda."
  }

  assert {
    condition     = output.control_plane_backend_name == "honua-gitops-aws-lambda"
    error_message = "Expected backend name honua-gitops-aws-lambda."
  }

  assert {
    condition     = output.control_plane_telemetry_policy == "honua-http"
    error_message = "Expected telemetry policy honua-http."
  }
}
