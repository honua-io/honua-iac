# The serverless root forwards domain_name / route53_zone_id (same names as the
# ECS root, examples/aws) to modules/aws-serverless, and honua_url follows the
# module's service_url: https://<domain_name> when the custom domain is set,
# the execute-api endpoint otherwise (owner decision 11; honua-iac#223).
# Mocked providers; no AWS calls.

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
      api_endpoint  = "https://abcdefghij.execute-api.us-east-1.amazonaws.com"
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

run "without_a_domain_honua_url_is_execute_api" {
  command = apply

  assert {
    condition     = output.honua_url == "https://abcdefghij.execute-api.us-east-1.amazonaws.com" && output.api_endpoint == output.honua_url
    error_message = "Without domain_name honua_url must stay the execute-api endpoint."
  }

  assert {
    condition     = output.custom_domain_url == null && output.custom_domain_alias_fqdn == null && output.custom_domain_certificate_arn == null
    error_message = "Without domain_name the root must report no custom domain."
  }
}

run "domain_inputs_pass_through_and_honua_url_is_https" {
  command = apply

  variables {
    domain_name     = "honuarawsse380460-it.cert.demo.honua.io"
    route53_zone_id = "Z089181827C9GKIKHXUTT"
  }

  assert {
    condition     = output.honua_url == "https://honuarawsse380460-it.cert.demo.honua.io" && output.custom_domain_url == output.honua_url
    error_message = "With domain_name and route53_zone_id honua_url must be the https custom domain."
  }

  assert {
    condition     = output.api_endpoint == "https://abcdefghij.execute-api.us-east-1.amazonaws.com"
    error_message = "api_endpoint must keep reporting the execute-api endpoint."
  }

  assert {
    condition     = output.custom_domain_alias_fqdn != null && output.custom_domain_certificate_arn != null
    error_message = "The root must expose the module-owned alias record and certificate the release teardown checks."
  }

  assert {
    condition     = local.deploy_contract.endpoint == "https://honuarawsse380460-it.cert.demo.honua.io"
    error_message = "The deploy contract endpoint must follow the custom domain, as on the ECS root."
  }
}
