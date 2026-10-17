# Redis operation key-ring certificate on Lambda (honua-iac#213 follow-up).
#
# A connected Redis makes the server compose the durable operation secret
# channel, which refuses to start without the key-ring certificate. Lambda
# cannot resolve Secrets Manager into env, so the module must hand the function
# an aws:secretsmanager: REFERENCE (never the value), grant the function roles
# read on exactly that secret, fail planning when Redis is on without it, and
# leave Redis-off cells with no certificate dependency.

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

  # Control-plane event targets and schedules validate these ARNs in-provider.
  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:123456789012:function:honua-mock"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/honua-mock"
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
  redis_enabled    = false
  redis_auth_token = "aaaaAAAA1111&&&&aaaaAAAA1111&&&&"
}


# Synthetic references and mocked providers: no AWS calls or private seed reads.
run "disabled_preserves_existing_environment_contract" {
  command = apply
  variables {
    additional_env = { StudioAiProxy__TranscriptSigning__KeyId = "legacy", StudioAiProxy__TranscriptSigning__PrivateKeyReference = "env://LEGACY_SIGNER" }
  }
  assert {
    condition     = length(aws_iam_role_policy.transcript_signing) == 0 && length(local.transcript_signing_environment) == 0 && aws_lambda_function.this.environment[0].variables["StudioAiProxy__TranscriptSigning__KeyId"] == "legacy"
    error_message = "Null adds no signer permissions or configuration and preserves existing additional_env."
  }
}
run "runtime_versioned_reference_has_exact_function_role_grants" {
  command = apply
  variables {
    transcript_signing = {
      key_id      = "approved-model-key"
      secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123"
      version_id  = "00000000-0000-0000-0000-000000000008"
      kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007"
    }
    enable_control_plane_events = true
  }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables["StudioAiProxy__TranscriptSigning__KeyId"] == "approved-model-key" && aws_lambda_function.this.environment[0].variables["StudioAiProxy__TranscriptSigning__PrivateKeyReference"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123?versionId=00000000-0000-0000-0000-000000000008" && !contains(keys(aws_lambda_function.this.environment[0].variables), "HONUA_TRANSCRIPT_SIGNING_KEY")
    error_message = "Lambda carries the exact runtime reference and public key ID, never the private seed."
  }
  assert {
    condition = aws_iam_role_policy.transcript_signing[0].role == aws_iam_role.lambda.id && jsondecode(aws_iam_role_policy.transcript_signing[0].policy).Statement == [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123"] },
    { Effect = "Allow", Action = ["kms:Decrypt"], Resource = ["arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007"] }]
    error_message = "Only the HTTP function role receives exact secret-read and decrypt grants."
  }
  assert {
    condition     = alltrue([for environment in [aws_lambda_function.control_plane_reconcile[0].environment[0].variables, aws_lambda_function.control_plane_backstop[0].environment[0].variables, aws_lambda_function.control_plane_tick[0].environment[0].variables] : !anytrue([for key in keys(environment) : startswith(key, "StudioAiProxy__TranscriptSigning__")])]) && !contains(local.lambda_secret_arns, "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123")
    error_message = "Event-only functions neither inherit signer references nor receive signer read grants."
  }
  assert {
    condition     = local.lambda_environment_bytes.api <= 4096 && aws_lambda_function.this.environment[0].variables["Licensing__Mode"] == "Disabled"
    error_message = "Signing must retain the 4 KiB guard and existing licensing defaults."
  }
}
run "signing_cannot_bypass_lambda_environment_budget" {
  command = plan
  variables {
    transcript_signing = {
      key_id      = "approved-model-key"
      secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123"
      version_id  = "00000000-0000-0000-0000-000000000008"
      kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007"
    }
    additional_env = { HONUA_PADDING = format("%4096s", "x") }
  }
  expect_failures = [aws_lambda_function.this]
}
run "optional_version_and_kms_remain_absent" {
  command = apply
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123" } }
  assert {
    condition     = aws_lambda_function.this.environment[0].variables["StudioAiProxy__TranscriptSigning__PrivateKeyReference"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123" && length(jsondecode(aws_iam_role_policy.transcript_signing[0].policy).Statement) == 1
    error_message = "An unpinned operator configuration must not invent a version or a KMS grant; certification pins it separately."
  }
}
run "reject_empty_key" {
  command = plan
  variables { transcript_signing = { key_id = "", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123", version_id = "00000000-0000-0000-0000-000000000008", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007" } }
  expect_failures = [var.transcript_signing]
}
run "reject_empty_secret" {
  command = plan
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "", version_id = "00000000-0000-0000-0000-000000000008", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007" } }
  expect_failures = [var.transcript_signing]
}
run "reject_inline_seed" {
  command = plan
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", version_id = "00000000-0000-0000-0000-000000000008", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007" } }
  expect_failures = [var.transcript_signing]
}
run "reject_wildcard_secret" {
  command = plan
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123*", version_id = "00000000-0000-0000-0000-000000000008", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007" } }
  expect_failures = [var.transcript_signing]
}
run "reject_secret_selector" {
  command = plan
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123:::AWSCURRENT", version_id = "00000000-0000-0000-0000-000000000008", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007" } }
  expect_failures = [var.transcript_signing]
}
run "reject_unsupported_reference" {
  command = plan
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "env://KEY", version_id = "00000000-0000-0000-0000-000000000008", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007" } }
  expect_failures = [var.transcript_signing]
}
run "reject_short_version" {
  command = plan
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123", version_id = "short", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007" } }
  expect_failures = [var.transcript_signing]
}
run "reject_version_selector" {
  command = plan
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123", version_id = "?versionId=00000000-0000-0000-0000-000000000008", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007" } }
  expect_failures = [var.transcript_signing]
}
run "reject_long_version" {
  command = plan
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123", version_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007" } }
  expect_failures = [var.transcript_signing]
}
run "reject_kms_alias" {
  command = plan
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123", version_id = "00000000-0000-0000-0000-000000000008", kms_key_arn = "alias/aws/secretsmanager" } }
  expect_failures = [var.transcript_signing]
}
run "reject_kms_wildcard" {
  command = plan
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123", version_id = "00000000-0000-0000-0000-000000000008", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007*" } }
  expect_failures = [var.transcript_signing]
}
run "reject_malformed_kms_id" {
  command = plan
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123", version_id = "00000000-0000-0000-0000-000000000008", kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/not-a-key" } }
  expect_failures = [var.transcript_signing]
}
run "reject_aliased_settings_when_configured" {
  command = plan
  variables {
    transcript_signing = {
      key_id      = "approved-model-key"
      secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123"
      version_id  = "00000000-0000-0000-0000-000000000008"
      kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007"
    }
    additional_env = { "studioaiproxy:transcriptsigning:keyid" = "other" }
  }
  expect_failures = [terraform_data.transcript_signing_validation]
}
run "reject_private_key_env_when_configured" {
  command = plan
  variables {
    transcript_signing = {
      key_id      = "approved-model-key"
      secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123"
      version_id  = "00000000-0000-0000-0000-000000000008"
      kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007"
    }
    additional_env = { honua_transcript_signing_key = "inline-seed" }
  }
  expect_failures = [terraform_data.transcript_signing_validation]
}
