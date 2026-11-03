# Layer-publish budget (layer_publishing_materialization_timeout_seconds).
#
# Known issue in 2026.1-rc.2 (honua-server#6917): a very large layer publish can
# exceed honua-server's default 300 s LayerPublishing__MaterializationTimeoutSeconds.
# The root renders the optional input into the module's additional_env only when it
# is set; null (default) renders nothing and keeps the server default. The value
# must be a whole number from 1 to 3600, the server's documented range.
# Mocked providers; plan only; no credentials, no AWS calls.

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

run "null_by_default_renders_nothing" {
  command = plan

  assert {
    condition     = var.layer_publishing_materialization_timeout_seconds == null && !contains(keys(local.server_additional_env), "LayerPublishing__MaterializationTimeoutSeconds")
    error_message = "layer_publishing_materialization_timeout_seconds must default to null and add nothing to additional_env."
  }

  assert {
    condition     = local.server_additional_env["HONUA_ADMIN_UI"] == "true" && local.server_additional_env["HONUA_SERVE_ADMIN_UI"] == "true"
    error_message = "The root's fixed server settings must still be rendered."
  }
}

run "six_hundred_seconds_renders_the_budget" {
  command = plan

  variables {
    layer_publishing_materialization_timeout_seconds = 600
  }

  assert {
    condition     = local.server_additional_env["LayerPublishing__MaterializationTimeoutSeconds"] == "600"
    error_message = "layer_publishing_materialization_timeout_seconds = 600 must render LayerPublishing__MaterializationTimeoutSeconds=600."
  }
}

run "zero_is_rejected" {
  command = plan

  variables {
    layer_publishing_materialization_timeout_seconds = 0
  }

  expect_failures = [var.layer_publishing_materialization_timeout_seconds]
}

run "above_3600_is_rejected" {
  command = plan

  variables {
    layer_publishing_materialization_timeout_seconds = 3601
  }

  expect_failures = [var.layer_publishing_materialization_timeout_seconds]
}

run "fraction_is_rejected" {
  command = plan

  variables {
    layer_publishing_materialization_timeout_seconds = 600.5
  }

  expect_failures = [var.layer_publishing_materialization_timeout_seconds]
}
