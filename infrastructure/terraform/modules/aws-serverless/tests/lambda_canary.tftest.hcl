mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      id     = "us-east-1"
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      partition          = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-1:123456789012:repository/honua-server"
      registry_id    = "123456789012"
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_lambda_function" {
    defaults = {
      arn     = "arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua"
      version = "43"
    }
  }

  mock_resource "aws_lambda_alias" {
    defaults = {
      arn        = "arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua:live"
      invoke_arn = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua:live/invocations"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/honua-test"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/honua-test"
    }
  }

  mock_resource "aws_batch_compute_environment" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:compute-environment/honua-mock"
    }
  }

  mock_resource "aws_batch_job_queue" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:job-queue/honua-mock"
    }
  }

  mock_resource "aws_batch_job_definition" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:job-definition/honua-mock:1"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:honua-mock:*"
    }
  }

  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      arn           = "arn:aws:apigateway:us-east-1::/apis/abcdefghij"
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abcdefghij"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-mock-AbCdEf"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  name_prefix                = "honua-contract"
  environment                = "dev"
  lambda_alias_version       = "42"
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"
  # checkov:skip=CKV_SECRET_6: Synthetic test-only database password.
  db_password = "Synthetic-Terraform-Test-Db-4721aA1"

  redis_auth_token = "aaaaAAAA1111&&&&aaaaAAAA1111&&&&"

  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
}

run "default_alias_has_no_weights_and_document_is_unchanged" {
  command = apply

  assert {
    condition = (
      length(aws_lambda_alias.live.routing_config) == 0 &&
      local.runtime_settings_hash == "c416671c63ab6546f665c18acc93b9a1547470d2284d7930f1594a5add80a41e" &&
      !contains(keys(jsondecode(local.runtime_settings_json).ControlPlane), "TelemetryConnections") &&
      length(aws_iam_role_policy.lambda_deploy_telemetry) == 0 &&
      output.lambda_deploy_canary == null
    )
    error_message = "Without canary inputs the alias must carry no routing_config and the settings document hash must be unchanged."
  }
}

run "static_alias_routing_renders_additional_version_weight" {
  command = apply

  variables {
    lambda_alias_routing = {
      additional_version = "43"
      weight             = 0.1
    }
  }

  assert {
    condition = (
      aws_lambda_alias.live.function_version == "42" &&
      aws_lambda_alias.live.routing_config[0].additional_version_weights["43"] == 0.1 &&
      local.runtime_settings_hash == "c416671c63ab6546f665c18acc93b9a1547470d2284d7930f1594a5add80a41e"
    )
    error_message = "lambda_alias_routing must send the configured share to the additional version without changing the deploy registry."
  }
}

run "alias_routing_to_the_alias_version_is_rejected" {
  command = plan

  variables {
    lambda_alias_routing = {
      additional_version = "42"
      weight             = 0.1
    }
  }

  expect_failures = [aws_lambda_alias.live]
}

run "alias_routing_weight_bounds_are_enforced" {
  command = plan

  variables {
    lambda_alias_routing = {
      additional_version = "43"
      weight             = 1
    }
  }

  expect_failures = [var.lambda_alias_routing]
}

run "control_plane_canary_extends_target_and_connection" {
  # A changed settings document needs its predecessor retained; use a fresh
  # state so this scenario does not plan to destroy the default document.
  state_key = "lambda_deploy_canary"
  command   = apply

  variables {
    lambda_deploy_canary = {
      weight_percentage    = 10
      error_rate_threshold = 0.02
    }
  }

  assert {
    condition = (
      jsondecode(local.runtime_settings_json).ControlPlane.DeployTargets[0].Backend == "honua-gitops-aws-lambda" &&
      jsondecode(local.runtime_settings_json).ControlPlane.DeployTargets[0].Parameters["aws.lambda.canary_weight_percentage"] == "10" &&
      jsondecode(local.runtime_settings_json).ControlPlane.DeployTargets[0].Parameters["telemetry.connection"] == "aws-cloudwatch" &&
      jsondecode(local.runtime_settings_json).ControlPlane.DeployTargets[0].Parameters["telemetry.sample_count.minimum"] == "50" &&
      jsondecode(local.runtime_settings_json).ControlPlane.DeployTargets[0].Parameters["telemetry.error_rate.threshold"] == "0.02" &&
      jsondecode(local.runtime_settings_json).ControlPlane.DeployTargets[0].Parameters["aws.lambda.alias_name"] == "live" &&
      !contains(keys(jsondecode(local.runtime_settings_json).ControlPlane.DeployTargets[0].Parameters), "telemetry.max_staleness_seconds") &&
      !contains(keys(jsondecode(local.runtime_settings_json).ControlPlane.DeployTargets[0].Parameters), "telemetry.sample_count.query") &&
      jsondecode(local.runtime_settings_json).ControlPlane.TelemetryConnections[0].ConnectionId == "aws-cloudwatch" &&
      jsondecode(local.runtime_settings_json).ControlPlane.TelemetryConnections[0].Provider == "cloudwatch" &&
      jsondecode(local.runtime_settings_json).ControlPlane.TelemetryConnections[0].BaseUrl == "https://monitoring.us-east-1.amazonaws.com" &&
      jsondecode(local.runtime_settings_json).ControlPlane.TelemetryConnections[0].Region == "us-east-1" &&
      local.runtime_settings_hash != "c416671c63ab6546f665c18acc93b9a1547470d2284d7930f1594a5add80a41e"
    )
    error_message = "The control-plane canary must add the weight, gate parameters and a CloudWatch connection to the version-pinned settings document, without target-level aggregate queries or CloudWatch-rejected keys."
  }

  assert {
    condition = (
      output.lambda_deploy_canary.status == "configured-unverified" &&
      output.lambda_deploy_canary.target_id == output.control_plane_target_id &&
      strcontains(output.lambda_deploy_canary.query_templates["telemetry.sample_count.query"], "ExecutedVersion=\"{version}\"") &&
      strcontains(output.lambda_deploy_canary.query_templates["telemetry.latency_p95.query"], "Resource=\"honua-contract-dev-honua:live\"") &&
      jsondecode(aws_iam_role_policy.lambda_deploy_telemetry[0].policy).Statement[0].Action == ["cloudwatch:GetMetricData"] &&
      aws_iam_role_policy.lambda_deploy_telemetry[0].role == aws_iam_role.lambda.id
    )
    error_message = "The handoff must expose candidate-scoped query templates and grant the API role CloudWatch metric reads."
  }
}

run "control_plane_canary_refuses_raw_connection_override" {
  # A changed settings document needs its predecessor retained; use a fresh
  # state so this scenario does not plan to destroy the default document.
  state_key = "lambda_deploy_canary_override"
  command   = plan

  variables {
    lambda_deploy_canary = {
      weight_percentage = 10
    }
    additional_env = {
      "ControlPlane__TelemetryConnections__0__BaseUrl" = "https://attacker.example.com"
    }
  }

  expect_failures = [aws_iam_role_policy.lambda_deploy_telemetry]
}

run "control_plane_canary_weight_bounds_are_enforced" {
  command = plan

  variables {
    lambda_deploy_canary = {
      weight_percentage = 100
    }
  }

  expect_failures = [var.lambda_deploy_canary]
}
