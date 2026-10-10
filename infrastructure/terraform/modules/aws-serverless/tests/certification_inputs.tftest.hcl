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
    bedrock_ai_model  = "anthropic.claude-sonnet-4-5-20250929-v1:0"
    additional_env    = { StudioAiProxy__Providers__bedrock__Model = "unapproved-model" }
  }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables["StudioAiProxy__Enabled"] == "true" && aws_lambda_function.this.environment[0].variables["StudioAiProxy__DefaultProvider"] == "bedrock" && aws_lambda_function.this.environment[0].variables["StudioAiProxy__Providers__bedrock__Kind"] == "bedrock"
    error_message = "StudioAiProxy must select the IAM-authenticated Bedrock adapter."
  }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables["StudioAiProxy__Providers__bedrock__Model"] == "anthropic.claude-sonnet-4-5-20250929-v1:0" && aws_lambda_function.this.environment[0].variables["StudioAiProxy__Providers__bedrock__Region"] == "us-east-1"
    error_message = "The running configuration must match the exact authorized model and region, despite additional_env."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.lambda_bedrock_invoke[0].policy).Statement[0].Resource) == toset(["arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0"])
    error_message = "A foundation model grant must contain exactly the pinned model ARN."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.lambda_bedrock_invoke[0].policy).Statement[0].Action) == toset(["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"])
    error_message = "Studio chat grants only inference, never model/agent administration."
  }
}
run "bedrock_disabled" {
  command = plan
  assert {
    condition     = length(aws_iam_role_policy.lambda_bedrock_invoke) == 0 && !contains(keys(local.bedrock_ai_environment), "StudioAiProxy__Enabled")
    error_message = "Disabled Bedrock must grant and configure nothing."
  }
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
