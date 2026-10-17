# Studio end-user authorization (studio_end_user_authorization).
#
# honua-server admits admins to the Studio authoring API unconditionally and
# other authenticated principals only when Studio:EndUserAuthorization:Enabled
# is true (e2e-cloud-aws run 38091905679: a non-admin got HTTP 403 on
# GET /api/v1/studio/package-families). The module renders the flag only when
# the input is true; off keeps the server default (admins only).

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

  honua_image_uri      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"
  # checkov:skip=CKV_SECRET_6: Synthetic test-only database password for mocked providers, not a credential.
  db_password    = "Synthetic-Terraform-Test-Db-4721aA1"
  redis_enabled  = false
  enable_postgis = false
}


run "signer_reaches_runtime_module" {
  command = plan
  variables { transcript_signing = {
    key_id      = "approved-model-key"
    secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123"
    version_id  = "00000000-0000-0000-0000-000000000008"
    kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007"
  } }
  assert {
    condition     = module.honua.transcript_signing_environment_rendered == tomap({ StudioAiProxy__TranscriptSigning__KeyId = "approved-model-key", StudioAiProxy__TranscriptSigning__PrivateKeyReference = "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123?versionId=00000000-0000-0000-0000-000000000008" })
    error_message = "The root must pass the exact approved public key ID and runtime reference to the module."
  }
}
run "root_rejects_partial_signer_pair" {
  command = plan
  variables { transcript_signing = { key_id = "", secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123" } }
  expect_failures = [var.transcript_signing]
}
