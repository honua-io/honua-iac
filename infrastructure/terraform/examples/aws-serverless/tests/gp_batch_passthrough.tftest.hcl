# GP on AWS Batch from the deployable serverless root (the 2026.1 Lambda+Batch
# cell), and the root's architecture defaults.
#
# The root must pass the Batch inputs through to modules/aws-serverless so an
# operator or the release harness can provision the cell from tfvars alone, and
# its defaults must match the 2026.1 platform manifest: Lambda
# awsLambdaArchitecture x86_64, generic ECS image awsEcsArchitecture x86_64.
# Plan-only with mocked providers; no credentials, no AWS calls.
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

run "defaults_match_the_manifest_and_leave_batch_off" {
  command = plan

  assert {
    condition     = tolist(var.lambda_architectures) == tolist(["x86_64"]) && tolist(output.lambda_architectures) == tolist(["x86_64"])
    error_message = "The serverless root must default the Lambda to x86_64 (platform manifest awsLambdaArchitecture) and pass it to the function."
  }

  assert {
    condition     = var.gp_batch_cpu_architecture == "X86_64"
    error_message = "The GP Batch architecture must default to X86_64 (platform manifest awsEcsArchitecture for the generic image)."
  }

  assert {
    condition     = output.gp_batch_enabled == false && output.gp_job_queue_name == null && output.gp_job_definition_names == null && output.gp_compute_environment_name == null
    error_message = "Batch is off by default and must provision and output nothing."
  }

  assert {
    condition     = output.migrate_required == true
    error_message = "With skip_migrations at its default the root must report that an out-of-band migration is required."
  }
}

run "batch_inputs_pass_through_to_the_module" {
  command = plan

  variables {
    enable_gp_batch               = true
    gp_batch_image                = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    gp_batch_max_vcpus            = 8
    use_batch_service_linked_role = true
  }

  assert {
    condition     = output.gp_batch_enabled == true
    error_message = "enable_gp_batch must reach the module."
  }

  assert {
    condition     = output.gp_batch_image == "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    error_message = "gp_batch_image (the generic ECS image) must reach the job definitions instead of the Lambda image."
  }

  assert {
    condition     = output.gp_batch_cpu_architecture == "X86_64"
    error_message = "The Batch job definitions must run X86_64 by default."
  }

  assert {
    condition     = output.gp_job_queue_name != null && output.gp_compute_environment_name != null && toset(keys(output.gp_job_definition_names)) == toset(["s", "m", "l", "xl"])
    error_message = "The root must output the job queue, compute environment and the s/m/l/xl job-definition pool names."
  }
}

run "batch_architecture_passes_through" {
  command = plan

  variables {
    enable_gp_batch           = true
    gp_batch_image            = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    gp_batch_cpu_architecture = "ARM64"
    lambda_architectures      = ["arm64"]
  }

  assert {
    condition     = output.gp_batch_cpu_architecture == "ARM64" && tolist(output.lambda_architectures) == tolist(["arm64"])
    error_message = "Explicit architecture overrides must reach the module."
  }
}

run "batch_without_a_generic_image_warns" {
  command = plan

  variables {
    enable_gp_batch = true
  }

  expect_failures = [check.gp_batch_image_is_generic]
}