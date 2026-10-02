# Image repository policy ownership (honua-iac #214).
#
# ECR holds one policy document per repository. A stack that owns its image
# repository installs the Lambda retrieval policy; a stack that consumes a shared
# repository (the standing honua-server repository every certification cell
# installs from) must never write or delete that document — the cell role is
# explicitly denied ecr:SetRepositoryPolicy there (honua-iac #208). This file
# runs from fresh state so a reuse-mode plan proves there is no policy to create,
# replace or delete.

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
}

run "reuse_shared_repository_manages_no_policy" {
  command = plan
  variables {
    image_repository_policy_mode = "reuse"
    lambda_architectures         = ["arm64"]
    enable_control_plane_events  = true
  }
  assert {
    condition     = length(aws_ecr_repository_policy.lambda_image_access) == 0
    error_message = "Reuse mode must not manage the shared repository's policy (no create, replace or delete)."
  }
  assert {
    condition     = length(data.aws_ecr_repository.image) == 0 && length(data.aws_iam_policy_document.lambda_ecr_access) == 0
    error_message = "Reuse mode must make no ECR control-plane read for a repository it does not own."
  }
  assert {
    condition     = aws_lambda_function.this.image_uri == var.image && aws_lambda_function.this.architectures == tolist(["arm64"])
    error_message = "Reuse mode must still install the exact immutable digest on the requested architecture."
  }
  assert {
    condition     = aws_lambda_function.control_plane_reconcile[0].image_uri == var.image
    error_message = "Control-plane Lambdas must install the same digest in reuse mode."
  }
}

run "reuse_accepts_cross_account_shared_repository" {
  command = plan
  variables {
    image_repository_policy_mode = "reuse"
    image                        = "210987654321.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
  assert {
    condition     = length(aws_ecr_repository_policy.lambda_image_access) == 0 && aws_lambda_function.this.image_uri == var.image
    error_message = "A repository owned by another account is consumable only through reuse, and reuse writes no policy on it."
  }
}

run "reuse_refuses_mutable_tag" {
  command = plan
  variables {
    image_repository_policy_mode = "reuse"
    image                        = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server:latest"
  }
  expect_failures = [var.image]
}

run "owned_default_installs_lambda_retrieval_policy" {
  command = plan
  assert {
    condition     = var.image_repository_policy_mode == "owned"
    error_message = "Owned must remain the default so existing stacks keep the policy they installed."
  }
  assert {
    condition     = length(aws_ecr_repository_policy.lambda_image_access) == 1 && aws_ecr_repository_policy.lambda_image_access[0].repository == "honua-server"
    error_message = "Owned mode must install the policy on the image's own repository."
  }
  assert {
    condition = (
      toset(data.aws_iam_policy_document.lambda_ecr_access[0].statement[0].actions) == toset(["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]) &&
      data.aws_iam_policy_document.lambda_ecr_access[0].statement[0].effect == "Allow" &&
      toset(tolist(data.aws_iam_policy_document.lambda_ecr_access[0].statement[0].principals)[0].identifiers) == toset(["lambda.amazonaws.com"])
    )
    error_message = "The owned policy must grant only Lambda image retrieval to the Lambda service."
  }
  assert {
    condition     = toset(tolist(data.aws_iam_policy_document.lambda_ecr_access[0].statement[0].condition)[0].values) == toset(["arn:aws:lambda:us-east-1:123456789012:function:*"])
    error_message = "The owned policy must be scoped to this account's Lambda functions in this region."
  }
}

run "owned_refuses_repository_in_another_account" {
  command = plan
  variables {
    image_repository_policy_mode = "owned"
    image                        = "210987654321.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
  expect_failures = [aws_ecr_repository_policy.lambda_image_access]
}

run "owned_refuses_repository_in_another_region" {
  command = plan
  variables {
    image_repository_policy_mode = "owned"
    image                        = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
  expect_failures = [aws_ecr_repository_policy.lambda_image_access]
}

run "unknown_mode_refused" {
  command = plan
  variables {
    image_repository_policy_mode = "managed"
  }
  expect_failures = [var.image_repository_policy_mode]
}
