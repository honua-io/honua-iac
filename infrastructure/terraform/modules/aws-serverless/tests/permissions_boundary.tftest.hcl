# Workload boundaries must survive every optional compute and event path.
# Batch infrastructure uses its separate operator-created service-linked role.

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

run "workload_boundary" {
  command = plan
  variables {
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/honua-release-cell-workload-boundary"
  }
  assert {
    condition     = aws_iam_role.lambda.permissions_boundary == var.permissions_boundary_arn
    error_message = "lambda must retain the operator boundary."
  }
}

run "auxiliary_roles_keep_the_boundary" {
  command = plan
  variables {
    permissions_boundary_arn      = "arn:aws:iam::123456789012:policy/honua-release-cell-workload-boundary"
    use_batch_service_linked_role = true
    enable_gp_batch               = true
    enable_customcode_batch       = true
    customcode_batch_image        = "registry.example/python@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    customcode_dotnet_batch_image = "registry.example/dotnet@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    enable_control_plane_events   = true
  }
  assert {
    condition = alltrue([
      length(aws_iam_role.batch_service) == 0,
      aws_iam_role.batch_execution[0].permissions_boundary == var.permissions_boundary_arn,
      aws_iam_role.batch_job[0].permissions_boundary == var.permissions_boundary_arn,
      aws_iam_role.customcode_execution[0].permissions_boundary == var.permissions_boundary_arn,
      aws_iam_role.customcode_job[0].permissions_boundary == var.permissions_boundary_arn,
      aws_iam_role.control_plane_events[0].permissions_boundary == var.permissions_boundary_arn,
      aws_iam_role.control_plane_scheduler[0].permissions_boundary == var.permissions_boundary_arn
    ])
    error_message = "All auxiliary Batch, custom-code and event roles must retain the operator boundary."
  }
}

run "workload_boundary_cannot_cap_batch_control_plane" {
  command = plan
  variables {
    permissions_boundary_arn      = "arn:aws:iam::123456789012:policy/honua-release-cell-workload-boundary"
    enable_gp_batch               = true
    use_batch_service_linked_role = false
  }
  expect_failures = [aws_batch_compute_environment.gp]
}
