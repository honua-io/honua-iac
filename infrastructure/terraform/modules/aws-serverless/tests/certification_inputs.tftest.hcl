# Licensing contract for the 2026.1 candidate (honua-iac #191, honua-server #4721).
#
# The 2026.1 release ships with licensing DISABLED. The module must DECLARE
# Licensing__Mode=Disabled rather than leave the Lambda on the server's own
# default (Mode=Enabled), which with no license source resolves to the Community
# edition and gates editing/sync/streaming/geocoding; and with no envelope it
# must create no license secret and grant the execution role no access to one.
#
# The expected values are the server's published contract, not a snapshot of this
# module's output: Licensing:Mode parses only "Enabled" | "Disabled"
# (honua-server src/Honua.Hosting/Features/Licensing/LicenseOptions.cs), and the
# envelope is resolved from Licensing:LicenseContentSecretRef =
# aws:secretsmanager:<arn> at startup.

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

run "bedrock_studio" {
  command = apply
  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
    bedrock_ai_model  = "anthropic.claude-sonnet-4-6"
    additional_env    = { StudioAiProxy__Providers__bedrock__Model = "unapproved-model" }
  }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables["StudioAiProxy__Enabled"] == "true" && aws_lambda_function.this.environment[0].variables["StudioAiProxy__DefaultProvider"] == "bedrock" && aws_lambda_function.this.environment[0].variables["StudioAiProxy__Providers__bedrock__Kind"] == "bedrock"
    error_message = "StudioAiProxy must select the IAM-authenticated Bedrock adapter."
  }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables["StudioAiProxy__Providers__bedrock__Model"] == "anthropic.claude-sonnet-4-6" && aws_lambda_function.this.environment[0].variables["StudioAiProxy__Providers__bedrock__Region"] == "us-east-1"
    error_message = "The running configuration must match the exact authorized model and region, despite additional_env."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.lambda_bedrock_invoke[0].policy).Statement[0].Resource) == toset(["arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6"])
    error_message = "A foundation model grant must contain exactly the pinned model ARN."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.lambda_bedrock_invoke[0].policy).Statement[0].Action) == toset(["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"])
    error_message = "Studio chat grants only inference, never model/agent administration."
  }
}
run "bedrock_latest_us_profiles" {
  command = plan
  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
    bedrock_ai_model  = "us.anthropic.claude-opus-5-5"
  }
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.lambda_bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-opus-5-5",
      "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-5-5",
      "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-opus-5-5",
      "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-opus-5-5",
    ])
    error_message = "Opus 5.5 grants exactly its US profile and the three member-region foundation models."
  }
}

run "bedrock_sonnet_5_5_profile" {
  command = plan
  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
    bedrock_ai_model  = "us.anthropic.claude-sonnet-5-5"
  }
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.lambda_bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-5-5",
    ])
    error_message = "Sonnet 5.5 grants exactly its US profile and the three member-region foundation models."
  }
}

run "bedrock_gpt_6_1_sol_profile" {
  command = plan
  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
    bedrock_ai_model  = "us.openai.gpt-6.1-sol"
  }
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.lambda_bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.openai.gpt-6.1-sol",
      "arn:aws:bedrock:us-east-1::foundation-model/openai.gpt-6.1-sol",
      "arn:aws:bedrock:us-east-2::foundation-model/openai.gpt-6.1-sol",
      "arn:aws:bedrock:us-west-2::foundation-model/openai.gpt-6.1-sol",
    ])
    error_message = "GPT-6.1 Sol grants exactly its US profile and the three member-region foundation models."
  }
}

run "bedrock_gpt_6_1_terra_profile" {
  command = plan
  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
    bedrock_ai_model  = "us.openai.gpt-6.1-terra"
  }
  assert {
    condition = toset(jsondecode(aws_iam_role_policy.lambda_bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.openai.gpt-6.1-terra",
      "arn:aws:bedrock:us-east-1::foundation-model/openai.gpt-6.1-terra",
      "arn:aws:bedrock:us-east-2::foundation-model/openai.gpt-6.1-terra",
      "arn:aws:bedrock:us-west-2::foundation-model/openai.gpt-6.1-terra",
    ])
    error_message = "GPT-6.1 Terra grants exactly its US profile and the three member-region foundation models."
  }
}

run "bedrock_disabled" {
  command = plan
  assert {
    condition     = length(aws_iam_role_policy.lambda_bedrock_invoke) == 0 && !contains(keys(local.bedrock_ai_environment), "StudioAiProxy__Enabled")
    error_message = "Disabled Bedrock must grant and configure nothing."
  }
}

run "studio_ai_proxy_limits_reach_the_settings_document" {
  # Publishing limits changes the retained settings document. A fresh state
  # keeps this plan from destroying the document the earlier runs published.
  state_key = "proxy_limits_full"
  command   = plan
  variables {
    enable_bedrock_ai      = true
    bedrock_ai_region      = "us-east-1"
    studio_ai_proxy_limits = { max_prompt_characters = 400000, max_request_bytes = 4194304, max_event_bytes = 4194304, max_response_bytes = 8388608 }
  }
  assert {
    condition = alltrue([for name, value in {
      MaxPromptCharacters = 400000
      MaxRequestBytes     = 4194304
      MaxEventBytes       = 4194304
      MaxResponseBytes    = 8388608
    } : local.runtime_settings_document.StudioAiProxy[name] == value]) && length([for key in keys(local.bedrock_ai_environment) : key if startswith(key, "StudioAiProxy__Max")]) == 0
    error_message = "Configured Studio AI proxy limits must reach the settings document the API loads, not the Lambda environment."
  }
}

run "studio_ai_proxy_limits_partial_and_absent" {
  state_key = "proxy_limits_partial"
  command   = plan
  variables {
    enable_bedrock_ai      = true
    bedrock_ai_region      = "us-east-1"
    studio_ai_proxy_limits = { max_event_bytes = 4194304, max_response_bytes = 8388608 }
  }
  assert {
    condition     = length(keys(local.runtime_settings_document.StudioAiProxy)) == 2 && local.runtime_settings_document.StudioAiProxy.MaxEventBytes == 4194304 && local.runtime_settings_document.StudioAiProxy.MaxResponseBytes == 8388608
    error_message = "Only the set limits are published; unset limits keep the server defaults."
  }
}

run "studio_ai_proxy_limits_without_bedrock_emit_nothing" {
  command = plan
  variables {
    studio_ai_proxy_limits = { max_prompt_characters = 400000 }
  }
  assert {
    condition     = length(local.bedrock_ai_environment) == 0 && !contains(keys(local.runtime_settings_document), "StudioAiProxy")
    error_message = "Without Bedrock the proxy is off and no limit is published."
  }
}

run "studio_ai_proxy_limits_reject_out_of_range" {
  command = plan
  variables {
    enable_bedrock_ai      = true
    studio_ai_proxy_limits = { max_prompt_characters = 600000 }
  }
  expect_failures = [var.studio_ai_proxy_limits]
}
run "reject_model_wildcard" {
  command = plan
  variables { bedrock_ai_model = "anthropic.*" }
  expect_failures = [var.bedrock_ai_model]
}

run "reject_unpinned_image_0" {
  command = plan
  variables { image = "ghcr.io/honua-io/honua-server:latest-lambda-aot-arm64" }
  expect_failures = [var.image]
}

run "reject_unpinned_image_1" {
  command = plan
  variables { image = "ghcr.io/honua-io/honua-server:v1.0.0" }
  expect_failures = [var.image]
}

run "reject_unpinned_image_2" {
  command = plan
  variables { image = "ghcr.io/honua-io/honua-server" }
  expect_failures = [var.image]
}

run "reject_unpinned_image_3" {
  command = plan
  variables { image = "ghcr.io/honua-io/honua-server@sha256:abc" }
  expect_failures = [var.image]
}

run "reject_mutable_gp_batch_image" {
  command = plan
  variables { gp_batch_image = "registry.example/honua:latest" }
  expect_failures = [var.gp_batch_image]
}

run "reject_mutable_customcode_batch_image" {
  command = plan
  variables { customcode_batch_image = "registry.example/honua:latest" }
  expect_failures = [var.customcode_batch_image]
}

run "reject_mutable_customcode_dotnet_batch_image" {
  command = plan
  variables { customcode_dotnet_batch_image = "registry.example/honua:latest" }
  expect_failures = [var.customcode_dotnet_batch_image]
}

run "reject_mutable_control_plane_events_image" {
  command = plan
  variables { control_plane_events_image = "registry.example/honua:latest" }
  expect_failures = [var.control_plane_events_image]
}
