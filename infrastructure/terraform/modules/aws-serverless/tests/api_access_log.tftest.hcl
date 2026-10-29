# API Gateway access log fields that place a slow request's time
# (honua-release e2e-cloud-aws run 40832719280).
#
# Three requests on the aws-serverless redis-off cell stalled 30 s and got the
# gateway's own 503 "Service Unavailable" (integration timeout). The access log
# then carried only status 503 and integrationStatus 200, and the function's
# log group had no "Task timed out", so whether the time went to a cold start,
# a queue or the handler could not be told apart once the cell was destroyed.
# The access log must carry the latencies and the Lambda RequestId that joins a
# request to its START/REPORT lines. Mocked providers; no AWS calls.

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

  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"
  redis_enabled  = false
}

run "access_log_places_the_time_of_a_request" {
  command = plan

  assert {
    condition = alltrue([
      for field, variable in {
        requestTimeEpoch     = "$context.requestTimeEpoch"
        responseLatency      = "$context.responseLatency"
        integrationLatency   = "$context.integrationLatency"
        integrationRequestId = "$context.integration.requestId"
        integrationError     = "$context.integration.error"
        integrationStatus    = "$context.integrationStatus"
        errorMessage         = "$context.error.message"
      } : try(jsondecode(aws_apigatewayv2_stage.this.access_log_settings[0].format)[field], "") == variable
    ])
    error_message = "The API access log must record the request start in ms, the response and integration latencies, the Lambda RequestId and the integration error next to the statuses."
  }
}
