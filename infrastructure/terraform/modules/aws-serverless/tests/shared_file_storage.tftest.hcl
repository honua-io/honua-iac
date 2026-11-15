# Shared S3 file storage (honua-server#5916, honua-release#548).
#
# A background import accepted by the API Lambda runs on the GP Batch workload,
# so the Lambda and the Batch worker must share FileStorage on S3: with the
# server's default Local provider the server answers background imports with 503
# (reasonCode shared-file-storage-required). file_storage_provider = "AwsS3"
# renders FileStorage__* on the API Lambda, the control-plane event functions and
# every GP Batch job-definition tier, and grants the three roles access under the
# key prefix. Local (the default) renders nothing and grants nothing.
#
# Mocked providers; no credentials, no AWS calls (the two rendering runs use a
# mocked apply, like lambda_environment_budget.tftest.hcl, so the functions'
# environments and the job definitions' container_properties are known). The Redis-on
# release-cell inputs match lambda_environment_budget.tftest.hcl, and the file
# storage inputs are exactly what the release harness passes on Redis-on cells
# (REDIS_ON_SCALE_INPUTS: file_storage_provider, file_storage_aws_s3_bucket_name,
# file_storage_aws_s3_key_prefix = release-cells/<name_prefix>).

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
      account_id = "585192672263"
      arn        = "arn:aws:iam::585192672263:user/terraform-test"
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
      arn            = "arn:aws:ecr:us-east-1:585192672263:repository/honua-server"
      registry_id    = "585192672263"
      repository_url = "585192672263.dkr.ecr.us-east-1.amazonaws.com/honua-server"
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
      arn = "arn:aws:iam::585192672263:policy/honua-test"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::585192672263:role/honua-test"
    }
  }
  mock_resource "aws_batch_compute_environment" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:585192672263:compute-environment/honua-mock"
    }
  }
  mock_resource "aws_batch_job_queue" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:585192672263:job-queue/honua-mock"
    }
  }
  mock_resource "aws_batch_job_definition" {
    defaults = {
      arn      = "arn:aws:batch:us-east-1:585192672263:job-definition/honua-mock:1"
      revision = 1
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:585192672263:log-group:honua-mock:*"
    }
  }
  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      arn           = "arn:aws:apigateway:us-east-1::/apis/abcdefghij"
      execution_arn = "arn:aws:execute-api:us-east-1:585192672263:abcdefghij"
    }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:585192672263:function:honua-mock"
    }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:585192672263:rule/honua-mock"
    }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-mock-AbCdEf"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  name_prefix                 = "honuarawsse380460"
  environment                 = "it"
  image                       = "585192672263.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:acae8755a327933e11718de3b0317b6a420a2444ec21135debcb6087adf3f12b"
  gp_batch_image              = "ghcr.io/honua-io/honua-server@sha256:961b983de43ede21d315770dd2e4e1f3bf41dc358ce8ed156ddcb3101a3b6bcc"
  admin_password              = "Synthetic-Terraform-Test-Admin-4721!aA1"
  redis_auth_token            = "aaaaAAAA1111&&&&aaaaAAAA1111&&&&"
  redis_enabled               = true
  enable_gp_batch             = true
  enable_control_plane_events = true
  licensing_mode              = "Disabled"

  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-release/cert/operation-key-ring-zDn618"
  audit_chain_key_secret_arn                = "arn:aws:secretsmanager:us-east-1:585192672263:secret:honua-release/cert/audit-chain-key-RLtpME"

  additional_env = {
    HONUA_SERVE_ADMIN_UI = "true"
    HONUA_ADMIN_UI       = "true"
  }
}

run "local_by_default_renders_nothing_and_grants_nothing" {
  # Mocked apply (no AWS calls): the functions' environments and the job
  # definitions' container_properties are only known after apply.
  command = apply

  assert {
    condition     = var.file_storage_provider == "Local" && !output.file_storage_shared && length(output.file_storage_environment_rendered.api) == 0 && length(output.file_storage_environment_rendered.control_plane) == 0 && length(output.file_storage_environment_rendered.gp_batch) == 0 && output.file_storage_s3_resources == null
    error_message = "file_storage_provider must default to Local and render no FileStorage__* settings."
  }

  assert {
    condition = alltrue([
      for env in [
        aws_lambda_function.this.environment[0].variables,
        aws_lambda_function.control_plane_reconcile[0].environment[0].variables,
        aws_lambda_function.control_plane_backstop[0].environment[0].variables,
        aws_lambda_function.control_plane_tick[0].environment[0].variables,
      ] : length([for k in keys(env) : k if startswith(k, "FileStorage__")]) == 0
    ])
    error_message = "With Local file storage no Lambda function may carry a FileStorage__* key."
  }

  assert {
    condition = alltrue([
      for tier in ["s", "m", "l", "xl"] :
      length([for e in jsondecode(aws_batch_job_definition.gp[tier].container_properties).environment : e if startswith(e.name, "FileStorage__")]) == 0
    ])
    error_message = "With Local file storage no GP Batch job definition may carry a FileStorage__* key."
  }

  assert {
    condition     = length(aws_iam_role_policy.lambda_file_storage_s3) == 0 && length(aws_iam_role_policy.control_plane_events_file_storage_s3) == 0 && length(aws_iam_role_policy.batch_job_file_storage_s3) == 0
    error_message = "With Local file storage the module must grant no S3 file-storage access."
  }
}

run "aws_s3_renders_on_every_server_process_and_grants_each_role" {
  # Mocked apply (no AWS calls): the functions' environments and the job
  # definitions' container_properties are only known after apply.
  command = apply

  variables {
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "release-cells-file-storage-585192672263"
    file_storage_aws_s3_key_prefix  = "release-cells/honuarawsse380460"
  }

  assert {
    condition = alltrue([
      for env in [
        aws_lambda_function.this.environment[0].variables,
        aws_lambda_function.control_plane_reconcile[0].environment[0].variables,
        aws_lambda_function.control_plane_backstop[0].environment[0].variables,
        aws_lambda_function.control_plane_tick[0].environment[0].variables,
        ] : nonsensitive(sensitive({ for k, v in env : k => v if startswith(k, "FileStorage__") })) == {
        FileStorage__Provider          = "AwsS3"
        FileStorage__AwsS3__BucketName = "release-cells-file-storage-585192672263"
        FileStorage__AwsS3__Region     = "us-east-1"
        FileStorage__AwsS3__KeyPrefix  = "release-cells/honuarawsse380460"
      }
    ])
    error_message = "AwsS3 must render FileStorage__Provider, __AwsS3__BucketName, __AwsS3__Region (the module region) and __AwsS3__KeyPrefix on the API Lambda and the three control-plane event functions."
  }

  assert {
    condition = alltrue([
      for tier in ["s", "m", "l", "xl"] :
      { for e in jsondecode(aws_batch_job_definition.gp[tier].container_properties).environment : e.name => e.value if startswith(e.name, "FileStorage__") } == {
        FileStorage__Provider          = "AwsS3"
        FileStorage__AwsS3__BucketName = "release-cells-file-storage-585192672263"
        FileStorage__AwsS3__Region     = "us-east-1"
        FileStorage__AwsS3__KeyPrefix  = "release-cells/honuarawsse380460"
      }
    ])
    error_message = "AwsS3 must render the same FileStorage__* settings on every GP Batch job-definition tier (s, m, l, xl)."
  }

  assert {
    condition = alltrue([
      for policy in [
        aws_iam_role_policy.lambda_file_storage_s3[0].policy,
        aws_iam_role_policy.control_plane_events_file_storage_s3[0].policy,
        aws_iam_role_policy.batch_job_file_storage_s3[0].policy,
        ] : jsondecode(policy).Statement == [
        {
          Sid      = "FileStorageBucket"
          Effect   = "Allow"
          Action   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
          Resource = ["arn:aws:s3:::release-cells-file-storage-585192672263"]
        },
        {
          Sid      = "FileStorageObjects"
          Effect   = "Allow"
          Action   = ["s3:AbortMultipartUpload", "s3:DeleteObject", "s3:GetObject", "s3:ListMultipartUploadParts", "s3:PutObject"]
          Resource = ["arn:aws:s3:::release-cells-file-storage-585192672263/release-cells/honuarawsse380460/*"]
        },
      ]
    ])
    error_message = "The API Lambda, control-plane event and GP Batch job roles must each get bucket-level access to the file-storage bucket and object access under the key prefix."
  }

  assert {
    condition = alltrue([
      aws_iam_role_policy.lambda_file_storage_s3[0].role == aws_iam_role.lambda.id,
      aws_iam_role_policy.control_plane_events_file_storage_s3[0].role == aws_iam_role.control_plane_events[0].id,
      aws_iam_role_policy.batch_job_file_storage_s3[0].role == aws_iam_role.batch_job[0].id,
    ])
    error_message = "Each file-storage grant must attach to its own role."
  }

  # The release Redis-on cell keeps the 256-byte margin with file storage on.
  assert {
    condition     = local.lambda_environment_bytes.api <= 4096 - 256 && local.lambda_environment_bytes.control_plane_tick <= 4096 - 256
    error_message = "With shared file storage the release cell's Lambda environment is about ${local.lambda_environment_bytes.api} bytes (API) and ${local.lambda_environment_bytes.control_plane_tick} bytes (scheduled tick); each must stay at least 256 bytes under 4096."
  }
}

run "explicit_region_and_empty_prefix" {
  command = plan

  variables {
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "honua-prod-files"
    file_storage_aws_s3_region      = "us-west-2"
    file_storage_aws_s3_key_prefix  = ""
    enable_control_plane_events     = false
    enable_gp_batch                 = false
  }

  assert {
    condition = alltrue([
      length(output.file_storage_environment_rendered.api) == 3,
      output.file_storage_environment_rendered.api["FileStorage__Provider"] == "AwsS3",
      output.file_storage_environment_rendered.api["FileStorage__AwsS3__BucketName"] == "honua-prod-files",
      output.file_storage_environment_rendered.api["FileStorage__AwsS3__Region"] == "us-west-2",
      output.file_storage_environment_rendered.control_plane == null,
      output.file_storage_environment_rendered.gp_batch == null,
    ])
    error_message = "An explicit region must be rendered as given, and an empty key prefix renders no KeyPrefix."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.lambda_file_storage_s3[0].policy).Statement[1].Resource == ["arn:aws:s3:::honua-prod-files/*"] && length(aws_iam_role_policy.control_plane_events_file_storage_s3) == 0 && length(aws_iam_role_policy.batch_job_file_storage_s3) == 0
    error_message = "With no key prefix the object grant covers the bucket; roles that are not deployed get no grant."
  }
}

run "aws_s3_without_a_bucket_fails_at_plan" {
  command = plan

  variables {
    file_storage_provider = "AwsS3"
  }

  expect_failures = [aws_lambda_function.this]
}

run "unknown_provider_is_rejected" {
  command = plan

  variables {
    file_storage_provider = "AzureBlob"
  }

  expect_failures = [var.file_storage_provider]
}

run "invalid_bucket_name_is_rejected" {
  command = plan

  variables {
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "Not_A_Bucket"
  }

  expect_failures = [var.file_storage_aws_s3_bucket_name]
}
