# Licensing contract for the 2026.1 candidate (honua-iac #191, honua-server #4721).
#
# The 2026.1 release ships with licensing DISABLED: the module must DECLARE
# Licensing__Mode=Disabled rather than leave the server on its own default
# (Mode=Enabled), which with no license source resolves to the Community edition
# and gates editing/sync/streaming/geocoding.
#
# The expected values here are the server's published contract, not a snapshot of
# this module's output:
#   * Licensing:Mode parses only "Enabled" | "Disabled"
#     (honua-server src/Honua.Hosting/Features/Licensing/LicenseOptions.cs).
#   * Licensing:Edition is nullable; a null edition with no license source means
#     Community, so a licensing-disabled deployment must not declare an edition.
#   * A supplied envelope is delivered inline as Licensing:LicenseContent and
#     verified against Licensing:TrustedKeys:<keyId>.

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

  mock_data "aws_elb_service_account" {
    defaults = {
      arn = "arn:aws:iam::127311923021:root"
      id  = "127311923021"
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

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/honua-test/0000000000000000"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/honua-test/0000000000000000"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/honua-test/0000000000000000/1111111111111111"
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
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  # Recommended in Production; unset only plans with a check warning.
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image                            = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  connection_encryption_master_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  existing_vpc_id             = "vpc-0123456789abcdef0"
  existing_vpc_cidr           = "10.0.0.0/16"
  existing_public_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
  existing_private_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]

  existing_db_endpoint          = "postgres.example.internal"
  existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"

  redis_enabled           = false
  kms_key_arn             = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
  alb_access_logs_enabled = false
}


# Synthetic references and mocked providers: no AWS calls or private seed reads.
run "disabled_preserves_existing_environment_contract" {
  command = apply
  variables {
    additional_env = { StudioAiProxy__TranscriptSigning__KeyId = "legacy", StudioAiProxy__TranscriptSigning__PrivateKeyReference = "env://LEGACY_SIGNER" }
  }
  assert {
    condition     = length(aws_iam_role_policy.transcript_signing) == 0 && length(local.transcript_signing_environment) == 0 && one([for e in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : e.value if e.name == "StudioAiProxy__TranscriptSigning__KeyId"]) == "legacy"
    error_message = "Null adds no signer permissions or configuration and preserves existing additional_env."
  }
}
run "native_versioned_secret_is_shared_by_serving_slots_only" {
  command = apply
  variables {
    transcript_signing = {
      key_id      = "approved-model-key"
      secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123"
      version_id  = "00000000-0000-0000-0000-000000000008"
      kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007"
    }
    canary_enabled                            = true
    deployment_mode                           = "MultiNode"
    redis_enabled                             = true
    redis_auth_token                          = "aA1aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    file_storage_provider                     = "AwsS3"
    file_storage_aws_s3_bucket_name           = "synthetic-model-files"
  }
  assert {
    condition = alltrue([for definition in [aws_ecs_task_definition.this.container_definitions, aws_ecs_task_definition.canary[0].container_definitions] :
      one([for e in jsondecode(definition)[0].environment : e.value if e.name == "StudioAiProxy__TranscriptSigning__KeyId"]) == "approved-model-key" &&
      one([for e in jsondecode(definition)[0].environment : e.value if e.name == "StudioAiProxy__TranscriptSigning__PrivateKeyReference"]) == "env://HONUA_TRANSCRIPT_SIGNING_KEY" &&
      one([for e in jsondecode(definition)[0].secrets : e.valueFrom if e.name == "HONUA_TRANSCRIPT_SIGNING_KEY"]) == "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123:::00000000-0000-0000-0000-000000000008" &&
    !contains([for e in jsondecode(definition)[0].environment : e.name], "HONUA_TRANSCRIPT_SIGNING_KEY")])
    error_message = "Both serving slots must inject the exact immutable secret through ECS, never a plaintext environment value."
  }
  assert {
    condition = aws_iam_role_policy.transcript_signing[0].role == aws_iam_role.task_execution.id && jsondecode(aws_iam_role_policy.transcript_signing[0].policy).Statement == [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123"] },
    { Effect = "Allow", Action = ["kms:Decrypt"], Resource = ["arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007"] }]
    error_message = "Only the execution role reads exactly the signer secret and configured KMS key."
  }
}
run "optional_version_and_kms_remain_absent" {
  command = apply
  variables { transcript_signing = { key_id = "approved-model-key", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123" } }
  assert {
    condition     = one([for s in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : s.valueFrom if s.name == "HONUA_TRANSCRIPT_SIGNING_KEY"]) == "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123" && length(jsondecode(aws_iam_role_policy.transcript_signing[0].policy).Statement) == 1
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
run "reject_canary_signer_override" {
  command = plan
  variables {
    transcript_signing = {
      key_id      = "approved-model-key"
      secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123"
      version_id  = "00000000-0000-0000-0000-000000000008"
      kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007"
    }
    canary_additional_env = { "StudioAiProxy:TranscriptSigning:PrivateKeyReference" = "env://OTHER" }
  }
  expect_failures = [terraform_data.transcript_signing_validation]
}
