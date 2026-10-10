# The serverless root forwards the operation key-ring certificate ARN to the
# module. With Redis on (the root default) the module refuses to plan without
# it, so a successful Redis-on plan proves the pass-through.

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
  enable_postgis = false
}

run "redis_on_root_forwards_the_certificate_arn" {
  command = apply

  variables {
    redis_enabled                                     = true
    operation_key_ring_certificate_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    operation_key_ring_certificate_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"
  }

  assert {
    condition     = output.deploy_contract.secret_refs["operation_key_ring_certificate"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    error_message = "The deploy contract must advertise the operator-owned certificate a Redis-on cell depends on."
  }
}

run "redis_off_deploy_contract_omits_the_certificate" {
  command = apply

  variables {
    redis_enabled                             = false
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }

  assert {
    condition     = !contains(keys(output.deploy_contract.secret_refs), "operation_key_ring_certificate")
    error_message = "Redis-off must not advertise the unused certificate."
  }
}

run "root_rejects_certificate_material" {
  command = plan

  variables {
    operation_key_ring_certificate_secret_arn = "YWFh"
  }

  expect_failures = [var.operation_key_ring_certificate_secret_arn]
}

run "root_rejects_a_kms_alias" {
  command = plan

  variables {
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    # checkov:skip=CKV_SECRET_6: The AWS-managed key alias name, not a credential.
    operation_key_ring_certificate_secret_kms_key_arn = "alias/aws/secretsmanager"
  }

  expect_failures = [var.operation_key_ring_certificate_secret_kms_key_arn]
}

run "deploy_contract_lists_the_audit_chain_key" {
  command = apply

  variables {
    redis_enabled              = false
    audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
  }

  assert {
    condition     = output.deploy_contract.secret_refs["audit_chain_key"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
    error_message = "The deploy contract must advertise the operator-owned audit-chain key."
  }
}
