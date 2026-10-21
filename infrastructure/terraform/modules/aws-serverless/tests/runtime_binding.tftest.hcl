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
  name_prefix          = "honua-contract"
  environment          = "dev"
  lambda_alias_version = "42"
  # Recommended in Production; unset only plans with a check warning.
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"

  # ElastiCache validates the auth token in-provider and the random provider is
  # mocked here, so supply one explicitly instead of auto-generating it.
  redis_auth_token = "aaaaAAAA1111&&&&aaaaAAAA1111&&&&"

  # Redis is on by default, which requires the operator key-ring certificate.
  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
}

run "handoff_reports_serving_alias_not_latest_function_version" {
  command = apply

  assert {
    condition     = output.runtime_binding_contract.resourceIdentity.publishedVersion == "42" && aws_lambda_function.this.version == "43"
    error_message = "The binding must identify the serving alias version, even when the function has a newer published version."
  }
  assert {
    condition     = output.runtime_binding_contract.resourceIdentity.apiGatewayIntegrationAliasArn == "arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua:live" && aws_apigatewayv2_route.root.target == "integrations/${output.runtime_binding_contract.resourceIdentity.apiGatewayIntegrationId}" && aws_apigatewayv2_route.proxy.target == "integrations/${output.runtime_binding_contract.resourceIdentity.apiGatewayIntegrationId}"
    error_message = "Both API routes and the actual integration URI must bind the same named Lambda alias."
  }
  assert {
    condition     = output.runtime_binding_contract.schemaVersion == "honua.runtime-binding/v1" && output.runtime_binding_contract.runtimeKind == "aws-lambda" && output.runtime_binding_contract.backend == "honua-gitops-aws-lambda" && output.runtime_binding_contract.platform.accountId == "123456789012" && output.runtime_binding_contract.platform.region == "us-east-1" && output.runtime_binding_contract.platform.partition == "aws" && output.runtime_binding_contract.targetId == "${aws_lambda_function.this.function_name}-${aws_lambda_alias.live.name}"
    error_message = "Runtime facts must preserve the provider account/region and canonical Lambda actuator."
  }
  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.runtime_settings.secret_string).ControlPlane.DeployTargets[0].TargetName == output.runtime_binding_contract.resourceIdentity.functionArn && jsondecode(aws_secretsmanager_secret_version.runtime_settings.secret_string).ControlPlane.DeployTargets[0].Parameters["aws.region"] == output.runtime_binding_contract.platform.region
    error_message = "The server registry must bind the actual function ARN and explicit provider region; the agent's cloud identity alone is insufficient."
  }
  assert {
    condition     = local.lambda_environment_bytes.api <= 4096 && local.lambda_environment_bytes.control_plane_tick <= 4096
    error_message = "Resource identity pins must fit within the unchanged Lambda environment limit."
  }
  assert {
    condition     = !contains(keys(output.runtime_binding_contract), "observation") && !strcontains(jsonencode(output.runtime_binding_contract), var.admin_password)
    error_message = "Configured facts must not contain credentials or claim live provider observation."
  }
}

run "nondefault_alias_preserves_region_and_alias_registration" {
  command = plan
  variables {
    lambda_alias_name = "candidate"
  }
  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.runtime_settings.secret_string).ControlPlane.DeployTargets[0].Parameters["aws.region"] == "us-east-1" && jsondecode(aws_secretsmanager_secret_version.runtime_settings.secret_string).ControlPlane.DeployTargets[0].Parameters["aws.lambda.alias_name"] == "candidate"
    error_message = "An explicit alias must not replace or hide the server's registered region."
  }
}

run "runtime_document_pins_versions_and_scopes_read_grants" {
  command = apply

  assert {
    condition = alltrue([
      for environment in [local.lambda_environment, local.control_plane_reconcile_environment, local.control_plane_backstop_environment, local.control_plane_tick_environment] :
      environment.HONUA_SETTINGS_DOCUMENT == "aws:secretsmanager:${aws_secretsmanager_secret.runtime_settings.name}?versionId=${aws_secretsmanager_secret_version.runtime_settings.version_id}"
    ])
    error_message = "Every function must pin the same settings version; alias rollback must not read AWSCURRENT."
  }
  assert {
    condition     = contains(jsondecode(aws_iam_policy.lambda_secrets.policy).Statement[0].Resource, aws_secretsmanager_secret.runtime_settings.arn) && contains(local.lambda_secret_arns, aws_secretsmanager_secret.runtime_settings.arn)
    error_message = "API and scheduled functions must have read permission on the exact runtime document secret."
  }
  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.runtime_settings.secret_string).ControlPlane.DeployTargets[0].RequiresOutOfBandMigrations && !strcontains(aws_secretsmanager_secret_version.runtime_settings.secret_string, var.admin_password)
    error_message = "Moving the target to JSON must retain the migration gate and exclude credentials."
  }
}

run "operator_cannot_replace_module_runtime_document" {
  command = plan
  variables {
    additional_env = { HONUA_SETTINGS_DOCUMENT = "aws:secretsmanager:foreign-config" }
  }
  expect_failures = [aws_secretsmanager_secret_version.runtime_settings]
}

run "operator_cannot_replace_module_runtime_document_alias" {
  command = plan
  variables {
    additional_env = { Settings__Document = "aws:secretsmanager:foreign-config" }
  }
  expect_failures = [aws_secretsmanager_secret_version.runtime_settings]
}

run "environment_cannot_retarget_registered_function" {
  command = plan
  variables {
    additional_env = { ControlPlane__DeployTargets__0__TargetName = "arn:aws:lambda:us-east-1:123456789012:function:unrelated" }
  }
  expect_failures = [aws_secretsmanager_secret_version.runtime_settings]
}

run "environment_cannot_override_case_insensitive_target_backend" {
  command = plan
  variables {
    additional_env = { controlplane__DEPLOYTARGETS__0__Backend = "honua-gitops-aws-ecs" }
  }
  expect_failures = [aws_secretsmanager_secret_version.runtime_settings]
}

run "environment_cannot_append_an_unregistered_deployment_target" {
  command = plan
  variables {
    additional_env = { ControlPlane__DeployTargets__1__TargetName = "arn:aws:lambda:us-east-1:123456789012:function:unrelated" }
  }
  expect_failures = [aws_secretsmanager_secret_version.runtime_settings]
}

run "unrelated_environment_settings_remain_available" {
  command = plan
  variables {
    additional_env = { Logging__LogLevel__Default = "Warning" }
  }
  assert {
    condition     = local.lambda_environment.Logging__LogLevel__Default == "Warning" && jsondecode(aws_secretsmanager_secret_version.runtime_settings.secret_string).ControlPlane.DeployTargets[0].TargetName == local.lambda_function_arn
    error_message = "Unrelated custom settings must remain available without changing the registered deployment target."
  }
}

run "long_alias_a_has_bounded_stable_target_id" {
  command = plan
  variables { lambda_alias_name = "${join("", [for _ in range(127) : "a"])}b" }
  override_resource {
    target = aws_lambda_alias.live
    values = { arn = "arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua:${join("", [for _ in range(127) : "a"])}b" }
  }
  assert {
    condition     = length(output.runtime_binding_contract.targetId) == 128 && output.runtime_binding_contract.targetId == "${substr(local.runtime_binding_lambda_target_name, 0, 95)}-${substr(sha256(local.runtime_binding_lambda_target_name), 0, 32)}" && output.runtime_binding_contract.resourceIdentity.aliasArn == aws_lambda_alias.live.arn
    error_message = "A valid maximum-length alias must retain its full authoritative ARN and emit a stable v1-bounded target ID."
  }
}

run "long_alias_b_with_same_prefix_has_distinct_target_id" {
  command = plan
  variables { lambda_alias_name = "${join("", [for _ in range(127) : "a"])}c" }
  override_resource {
    target = aws_lambda_alias.live
    values = { arn = "arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua:${join("", [for _ in range(127) : "a"])}c" }
  }
  assert {
    condition     = length(output.runtime_binding_contract.targetId) == 128 && substr(output.runtime_binding_contract.targetId, 0, 95) == substr(run.long_alias_a_has_bounded_stable_target_id.runtime_binding_contract.targetId, 0, 95) && output.runtime_binding_contract.targetId != run.long_alias_a_has_bounded_stable_target_id.runtime_binding_contract.targetId && output.runtime_binding_contract.resourceIdentity.aliasArn == aws_lambda_alias.live.arn
    error_message = "Distinct long aliases sharing the readable prefix must retain distinct bounded handoff IDs and full resource ARNs."
  }
}
