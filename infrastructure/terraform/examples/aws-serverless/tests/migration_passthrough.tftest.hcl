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

  mock_resource "aws_lambda_function" {
    defaults = {
      arn     = "arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua"
      version = "43"
    }
  }

  mock_resource "aws_lambda_alias" {
    defaults = {
      arn        = "arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua:live"
      invoke_arn = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua:live/invocations"
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
  name_prefix                        = "honua-contract"
  environment                        = "dev"
  lambda_alias_version               = "42"
  existing_db_endpoint               = "database.example"
  existing_db_connection_string      = "Host=database.example;Database=honua;Username=migrator;Password=synthetic-test-only"
  migration_image                    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  migration_packaged_manifest_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  # Recommended in Production; unset only plans with a check warning.
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  honua_image_uri      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"

  redis_enabled = false

  # Redis is on by default, which requires the operator key-ring certificate.
  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
}

override_resource {
  target = module.honua.aws_lambda_function.migration[0]
  values = {
    arn     = "arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-migration"
    version = "43"
  }
}

override_resource {
  target = module.honua.random_uuid.migration[0]
  values = { result = "62970000-0000-4000-8000-000000000001" }
}

override_resource {
  target = module.honua.aws_iam_role.migration[0]
  values = { arn = "arn:aws:iam::123456789012:role/honua-migration-test" }
}

override_resource {
  target = module.honua.aws_secretsmanager_secret.connection_string
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:direct-database-AbC123" }
}

override_resource {
  target = module.honua.aws_secretsmanager_secret_version.connection_string
  values = { version_id = "0123456789abcdef0123456789abcdef" }
}

override_resource {
  target = module.honua.aws_lambda_invocation.migration[0]
  values = { result = "{\n  \"schemaVersion\": \"honua.lambda-migration-run/v1\",\n  \"requestId\": \"provider-request-1\",\n  \"invokedFunctionArn\": \"arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-migration:43\",\n  \"functionVersion\": \"43\",\n  \"migration\": {\n    \"schemaVersion\": \"honua.migration-run/v1\",\n    \"runId\": \"62970000-0000-4000-8000-000000000001\",\n    \"outcome\": \"completed\",\n    \"provider\": \"postgres\",\n    \"schemaVerified\": true,\n    \"targetLocatorSha256\": \"33635ee2d208b8113be454ce8cb8293cdbc0014e16c14c54ca75f361163747d4\",\n    \"metadataSchema\": \"honua\",\n    \"packagedMigrationManifestSha256\": \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"\n  }\n}" }
}

run "preview_contract_passes_through_the_root" {
  command = apply
  assert {
    condition     = output.migration_contract.functionVersion == "43" && output.migration_contract.receipt.migration.schemaVerified && output.migrate_required == false
    error_message = "The root must expose the verified migration contract and avoid requiring a duplicate out-of-band run."
  }
}

run "default_root_keeps_external_initialization_required" {
  command = plan
  variables { migration_image = null }
  assert {
    condition     = output.migration_contract == null && output.migrate_required
    error_message = "The optional preview must not imply initialization in its default disabled configuration."
  }
}
