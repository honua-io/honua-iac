# Shared S3 file storage pass-through (file_storage_* inputs).
#
# The release harness passes file_storage_provider=AwsS3,
# file_storage_aws_s3_bucket_name=<bucket> and
# file_storage_aws_s3_key_prefix=release-cells/<cell> on Redis-on cells when the
# root declares them (REDIS_ON_SCALE_INPUTS in honua-release
# e2e/targets/terraform_target.py). The root passes them to the module, which
# renders FileStorage__* on the API Lambda, the control-plane event functions and
# the GP Batch job definitions, so a background import accepted by the Lambda can
# run on Batch (honua-server#5916). Local (default) renders nothing.
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


run "local_by_default_renders_nothing" {
  command = plan

  variables {
    enable_gp_batch             = true
    gp_batch_image              = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    enable_control_plane_events = true
  }

  assert {
    condition     = var.file_storage_provider == "Local" && !output.file_storage_shared && length(output.file_storage_environment_rendered.api) == 0 && length(output.file_storage_environment_rendered.control_plane) == 0 && length(output.file_storage_environment_rendered.gp_batch) == 0
    error_message = "file_storage_provider must default to Local and render no FileStorage__* settings on any server process."
  }
}

run "harness_inputs_reach_every_server_process" {
  command = plan

  variables {
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "release-cells-file-storage-585192672263"
    file_storage_aws_s3_key_prefix  = "release-cells/honuarawsse380460"
    enable_gp_batch                 = true
    gp_batch_image                  = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    enable_control_plane_events     = true
  }

  assert {
    condition = output.file_storage_shared && alltrue([
      for process in ["api", "control_plane", "gp_batch"] : alltrue([
        length(output.file_storage_environment_rendered[process]) == 4,
        output.file_storage_environment_rendered[process]["FileStorage__Provider"] == "AwsS3",
        output.file_storage_environment_rendered[process]["FileStorage__AwsS3__BucketName"] == "release-cells-file-storage-585192672263",
        output.file_storage_environment_rendered[process]["FileStorage__AwsS3__Region"] == "us-east-1",
        output.file_storage_environment_rendered[process]["FileStorage__AwsS3__KeyPrefix"] == "release-cells/honuarawsse380460",
      ])
    ])
    error_message = "The harness inputs must render FileStorage__Provider=AwsS3, the bucket, the root region (us-east-1) and the key prefix on the API Lambda, the control-plane event functions and the GP Batch job definitions."
  }

  assert {
    condition     = length(module.honua.file_storage_s3_resources) == 2 && module.honua.file_storage_s3_resources.object_arn == "arn:aws:s3:::release-cells-file-storage-585192672263/release-cells/honuarawsse380460/*"
    error_message = "The module must grant the file-storage roles object access under the harness key prefix."
  }
}
