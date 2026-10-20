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

  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"

  # ElastiCache validates the auth token in-provider and the random provider is
  # mocked here, so supply one explicitly instead of auto-generating it.
  redis_auth_token = "aaaaAAAA1111&&&&aaaaAAAA1111&&&&"

  # Redis is on by default, which requires the operator key-ring certificate.
  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
}

override_resource {
  target = aws_lambda_function.migration[0]
  values = {
    arn     = "arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-migration"
    version = "43"
  }
}

override_resource {
  target = random_uuid.migration[0]
  values = { result = "62970000-0000-4000-8000-000000000001" }
}

override_resource {
  target = aws_iam_role.migration[0]
  values = { arn = "arn:aws:iam::123456789012:role/honua-migration-test" }
}

override_resource {
  target = aws_secretsmanager_secret.connection_string
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:direct-database-AbC123" }
}

override_resource {
  target = aws_secretsmanager_secret_version.connection_string
  values = { version_id = "0123456789abcdef0123456789abcdef" }
}

override_resource {
  target = aws_lambda_invocation.migration[0]
  values = { result = "{\n  \"schemaVersion\": \"honua.lambda-migration-run/v1\",\n  \"requestId\": \"provider-request-1\",\n  \"invokedFunctionArn\": \"arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-migration:43\",\n  \"functionVersion\": \"43\",\n  \"migration\": {\n    \"schemaVersion\": \"honua.migration-run/v1\",\n    \"runId\": \"62970000-0000-4000-8000-000000000001\",\n    \"outcome\": \"completed\",\n    \"provider\": \"postgres\",\n    \"schemaVerified\": true,\n    \"targetLocatorSha256\": \"33635ee2d208b8113be454ce8cb8293cdbc0014e16c14c54ca75f361163747d4\",\n    \"metadataSchema\": \"honua\",\n    \"packagedMigrationManifestSha256\": \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"\n  }\n}" }
}

run "default_profile_has_no_migration_resources" {
  command = plan
  variables { migration_image = null }
  assert {
    condition     = length(aws_lambda_function.migration) == 0 && length(aws_lambda_invocation.migration) == 0 && length(aws_iam_role.migration) == 0 && length(aws_iam_role_policy.migration_tracing) == 0 && output.migration_contract == null
    error_message = "Existing configurations must not acquire a migration function, role or invocation."
  }
}

run "completed_receipt_binds_pinned_invocation_and_minimal_secret_access" {
  command = apply
  assert {
    condition     = aws_lambda_invocation.migration[0].qualifier == "43" && aws_lambda_invocation.migration[0].lifecycle_scope == "CREATE_ONLY" && jsondecode(aws_lambda_invocation.migration[0].input).runId == "62970000-0000-4000-8000-000000000001" && length(keys(jsondecode(aws_lambda_invocation.migration[0].input))) == 2
    error_message = "Only the version-pinned migration event and stable run identity may be invoked; destroy must not invoke SQL."
  }
  assert {
    condition     = aws_lambda_function.migration[0].environment[0].variables.ConnectionStrings__DefaultConnection == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:direct-database-AbC123?versionId=0123456789abcdef0123456789abcdef" && aws_lambda_function.migration[0].environment[0].variables.HONUA_MIGRATION_TARGET_SHA256 == "33635ee2d208b8113be454ce8cb8293cdbc0014e16c14c54ca75f361163747d4"
    error_message = "Migration must use the direct connection's exact secret version and canonical database locator hash."
  }
  assert {
    condition     = toset(keys(aws_lambda_function.migration[0].environment[0].variables)) == toset(["ASPNETCORE_ENVIRONMENT", "HONUA_MIGRATE_ONLY", "HONUA_MIGRATION_LAMBDA", "HONUA_SKIP_MIGRATIONS", "HONUA_MIGRATION_TARGET_SHA256", "HONUA_MIGRATION_MANIFEST_SHA256", "ConnectionStrings__DefaultConnection"]) && aws_lambda_function.migration[0].role != aws_lambda_function.this.role
    error_message = "Isolated migrations need their own role and no admin, Redis, licensing, encryption-key or serving settings."
  }
  assert {
    condition     = aws_lambda_function.migration[0].environment[0].variables.HONUA_MIGRATION_MANIFEST_SHA256 == var.migration_packaged_manifest_sha256 && aws_lambda_function.migration[0].environment[0].variables.HONUA_MIGRATION_MANIFEST_SHA256 == "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    error_message = "The immutable function configuration must supply the exact artifact manifest for the Server's check before secret resolution or SQL. The after-invocation postcondition alone is insufficient."
  }
  assert {
    condition     = tolist(jsondecode(aws_iam_role_policy.migration[0].policy).Statement[0].Resource) == tolist([aws_secretsmanager_secret.connection_string.arn]) && jsondecode(aws_iam_role_policy.migration[0].policy).Statement[0].Condition.StringEquals["secretsmanager:VersionId"] == "0123456789abcdef0123456789abcdef" && !strcontains(aws_iam_role_policy.migration[0].policy, "lambda:UpdateAlias")
    error_message = "Migration identity may read only its pinned database secret and cannot promote traffic."
  }
  assert {
    condition     = output.migration_contract.receipt.migration.schemaVerified && output.migration_contract.functionVersion == "43" && !strcontains(jsonencode(output.migration_contract), "synthetic-test-only")
    error_message = "The handoff must preserve the actual receipt without credentials."
  }
}

run "migration_network_permissions_exclude_function_code_and_other_vpcs" {
  command = apply
  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.migration[0].policy).Statement :
      statement.Sid == "CreateVpcNetworkInterface" ? (
        toset(statement.Action) == toset(["ec2:CreateNetworkInterface"]) &&
        toset(statement.Resource) == toset(concat(
          ["arn:aws:ec2:us-east-1:123456789012:network-interface/*", "arn:aws:ec2:us-east-1:123456789012:security-group/${aws_security_group.lambda.id}"],
          [for subnet in aws_lambda_function.migration[0].vpc_config[0].subnet_ids : "arn:aws:ec2:us-east-1:123456789012:subnet/${subnet}"]
        )) && statement.Condition.StringEquals["aws:RequestedRegion"] == "us-east-1"
        ) : statement.Sid == "MaintainVpcNetworkInterface" ? (
        toset(statement.Action) == toset(["ec2:DeleteNetworkInterface", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses"]) &&
        toset(statement.Resource) == toset(["arn:aws:ec2:us-east-1:123456789012:network-interface/*"]) &&
        statement.Condition.ArnEquals["ec2:Vpc"] == "arn:aws:ec2:us-east-1:123456789012:vpc/${aws_security_group.lambda.vpc_id}"
        ) : statement.Sid == "DenyFunctionCodeNetworkAdministration" ? (
        statement.Effect == "Deny" && statement.Resource == "*" &&
        statement.Condition.ArnEquals["lambda:SourceFunctionArn"] == aws_lambda_function.migration[0].arn &&
        toset(statement.Action) == toset(["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets", "ec2:DeleteNetworkInterface", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses"])
      ) : true
    ]) && length([for statement in jsondecode(aws_iam_role_policy.migration[0].policy).Statement : statement if contains(["CreateVpcNetworkInterface", "MaintainVpcNetworkInterface", "DenyFunctionCodeNetworkAdministration"], statement.Sid)]) == 3
    error_message = "The migration role must scope ENIs to the deployment account/region/network and deny network administration to function code."
  }
  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.migration[0].policy).Statement :
      statement.Effect == "Allow" && try(statement.Resource == "*", false) ? (
        toset(statement.Action) == toset(["ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets"]) &&
        statement.Condition.StringEquals["aws:RequestedRegion"] == "us-east-1"
      ) : true
    ]) && length(aws_iam_role_policy.migration_tracing) == 0 && alltrue([for statement in jsondecode(aws_iam_role_policy.migration[0].policy).Statement : statement.Sid != "WriteMigrationTraces"])
    error_message = "Default migrations allow only the regional Describe APIs on wildcard resources and do not grant unused tracing permissions."
  }
}

run "migration_tracing_uses_the_module_option_and_minimal_writer_permissions" {
  command = apply
  variables { enable_xray_tracing = true }
  assert {
    condition = aws_lambda_function.migration[0].tracing_config[0].mode == "Active" && length([
      for statement in jsondecode(aws_iam_role_policy.migration_tracing[0].policy).Statement : statement
      if statement.Sid == "WriteMigrationTraces" && toset(statement.Action) == toset(["xray:PutTraceSegments", "xray:PutTelemetryRecords"]) && statement.Condition.StringEquals["aws:RequestedRegion"] == "us-east-1"
    ]) == 1
    error_message = "Opt-in tracing must activate the migration function and grant only its regional trace writer APIs."
  }
}

run "no_nat_provisions_secret_reachability" {
  command = plan
  variables { enable_nat_gateway = false }
  assert {
    condition     = length(aws_vpc_endpoint.migration_secretsmanager) == 1 && aws_vpc_endpoint.migration_secretsmanager[0].private_dns_enabled && aws_vpc_endpoint.migration_secretsmanager[0].service_name == "com.amazonaws.us-east-1.secretsmanager"
    error_message = "No-NAT migrations require a private Secrets Manager network path."
  }
}

run "migration_endpoint_attaches_its_security_group" {
  command = apply
  variables { enable_nat_gateway = false }
  assert {
    condition     = length(aws_security_group.migration_secretsmanager) == 1 && toset(aws_vpc_endpoint.migration_secretsmanager[0].security_group_ids) == toset([aws_security_group.migration_secretsmanager[0].id]) && aws_security_group.migration_secretsmanager[0].vpc_id == aws_vpc_endpoint.migration_secretsmanager[0].vpc_id
    error_message = "The migration-only Secrets Manager endpoint must actually attach the migration endpoint security group in the same VPC."
  }
}

run "missing_manifest_blocks_before_invocation" {
  command = plan
  variables { migration_packaged_manifest_sha256 = null }
  expect_failures = [aws_lambda_function.migration]
}

run "serving_auto_migration_is_rejected" {
  command = plan
  variables { skip_migrations = false }
  expect_failures = [aws_lambda_function.migration]
}

run "moving_migration_tag_is_rejected" {
  command = plan
  variables { migration_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server:latest" }
  expect_failures = [var.migration_image]
}

run "unmanaged_image_repository_is_rejected" {
  command = plan
  variables { migration_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/other@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  expect_failures = [aws_lambda_function.migration]
}

run "ambiguous_metadata_schema_is_rejected" {
  command = plan
  variables { additional_env = { Database__Schema = "honua", "Database:Schema" = "other" } }
  expect_failures = [aws_lambda_function.migration]
}

run "wrong_run_blocks_serving_deployment" {
  command = apply
  # Runs share state: replace the prior CREATE_ONLY invocation so this
  # run must evaluate its own injected receipt instead of the earlier success.
  plan_options { replace = [aws_lambda_invocation.migration[0]] }
  override_resource {
    target = aws_lambda_invocation.migration[0]
    values = { result = "{\n  \"schemaVersion\": \"honua.lambda-migration-run/v1\",\n  \"requestId\": \"provider-request-1\",\n  \"invokedFunctionArn\": \"arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-migration:43\",\n  \"functionVersion\": \"43\",\n  \"migration\": {\n    \"schemaVersion\": \"honua.migration-run/v1\",\n    \"runId\": \"62970000-0000-4000-8000-000000000099\",\n    \"outcome\": \"completed\",\n    \"provider\": \"postgres\",\n    \"schemaVerified\": true,\n    \"targetLocatorSha256\": \"33635ee2d208b8113be454ce8cb8293cdbc0014e16c14c54ca75f361163747d4\",\n    \"metadataSchema\": \"honua\",\n    \"packagedMigrationManifestSha256\": \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"\n  }\n}" }
  }
  expect_failures = [aws_lambda_invocation.migration]
}

run "wrong_version_blocks_serving_deployment" {
  command = apply
  # Runs share state: replace the prior CREATE_ONLY invocation so this
  # run must evaluate its own injected receipt instead of the earlier success.
  plan_options { replace = [aws_lambda_invocation.migration[0]] }
  override_resource {
    target = aws_lambda_invocation.migration[0]
    values = { result = "{\n  \"schemaVersion\": \"honua.lambda-migration-run/v1\",\n  \"requestId\": \"provider-request-1\",\n  \"invokedFunctionArn\": \"arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-migration:43\",\n  \"functionVersion\": \"44\",\n  \"migration\": {\n    \"schemaVersion\": \"honua.migration-run/v1\",\n    \"runId\": \"62970000-0000-4000-8000-000000000001\",\n    \"outcome\": \"completed\",\n    \"provider\": \"postgres\",\n    \"schemaVerified\": true,\n    \"targetLocatorSha256\": \"33635ee2d208b8113be454ce8cb8293cdbc0014e16c14c54ca75f361163747d4\",\n    \"metadataSchema\": \"honua\",\n    \"packagedMigrationManifestSha256\": \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"\n  }\n}" }
  }
  expect_failures = [aws_lambda_invocation.migration]
}

run "wrong_arn_blocks_serving_deployment" {
  command = apply
  # Runs share state: replace the prior CREATE_ONLY invocation so this
  # run must evaluate its own injected receipt instead of the earlier success.
  plan_options { replace = [aws_lambda_invocation.migration[0]] }
  override_resource {
    target = aws_lambda_invocation.migration[0]
    values = { result = "{\n  \"schemaVersion\": \"honua.lambda-migration-run/v1\",\n  \"requestId\": \"provider-request-1\",\n  \"invokedFunctionArn\": \"arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-migration:44\",\n  \"functionVersion\": \"43\",\n  \"migration\": {\n    \"schemaVersion\": \"honua.migration-run/v1\",\n    \"runId\": \"62970000-0000-4000-8000-000000000001\",\n    \"outcome\": \"completed\",\n    \"provider\": \"postgres\",\n    \"schemaVerified\": true,\n    \"targetLocatorSha256\": \"33635ee2d208b8113be454ce8cb8293cdbc0014e16c14c54ca75f361163747d4\",\n    \"metadataSchema\": \"honua\",\n    \"packagedMigrationManifestSha256\": \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"\n  }\n}" }
  }
  expect_failures = [aws_lambda_invocation.migration]
}

run "wrong_target_blocks_serving_deployment" {
  command = apply
  # Runs share state: replace the prior CREATE_ONLY invocation so this
  # run must evaluate its own injected receipt instead of the earlier success.
  plan_options { replace = [aws_lambda_invocation.migration[0]] }
  override_resource {
    target = aws_lambda_invocation.migration[0]
    values = { result = "{\n  \"schemaVersion\": \"honua.lambda-migration-run/v1\",\n  \"requestId\": \"provider-request-1\",\n  \"invokedFunctionArn\": \"arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-migration:43\",\n  \"functionVersion\": \"43\",\n  \"migration\": {\n    \"schemaVersion\": \"honua.migration-run/v1\",\n    \"runId\": \"62970000-0000-4000-8000-000000000001\",\n    \"outcome\": \"completed\",\n    \"provider\": \"postgres\",\n    \"schemaVerified\": true,\n    \"targetLocatorSha256\": \"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\n    \"metadataSchema\": \"honua\",\n    \"packagedMigrationManifestSha256\": \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"\n  }\n}" }
  }
  expect_failures = [aws_lambda_invocation.migration]
}

run "wrong_manifest_blocks_serving_deployment" {
  command = apply
  # Runs share state: replace the prior CREATE_ONLY invocation so this
  # run must evaluate its own injected receipt instead of the earlier success.
  plan_options { replace = [aws_lambda_invocation.migration[0]] }
  override_resource {
    target = aws_lambda_invocation.migration[0]
    values = { result = "{\n  \"schemaVersion\": \"honua.lambda-migration-run/v1\",\n  \"requestId\": \"provider-request-1\",\n  \"invokedFunctionArn\": \"arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-migration:43\",\n  \"functionVersion\": \"43\",\n  \"migration\": {\n    \"schemaVersion\": \"honua.migration-run/v1\",\n    \"runId\": \"62970000-0000-4000-8000-000000000001\",\n    \"outcome\": \"completed\",\n    \"provider\": \"postgres\",\n    \"schemaVerified\": true,\n    \"targetLocatorSha256\": \"33635ee2d208b8113be454ce8cb8293cdbc0014e16c14c54ca75f361163747d4\",\n    \"metadataSchema\": \"honua\",\n    \"packagedMigrationManifestSha256\": \"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"\n  }\n}" }
  }
  expect_failures = [aws_lambda_invocation.migration]
}

run "unverified_schema_blocks_serving_deployment" {
  command = apply
  # Runs share state: replace the prior CREATE_ONLY invocation so this
  # run must evaluate its own injected receipt instead of the earlier success.
  plan_options { replace = [aws_lambda_invocation.migration[0]] }
  override_resource {
    target = aws_lambda_invocation.migration[0]
    values = { result = "{\n  \"schemaVersion\": \"honua.lambda-migration-run/v1\",\n  \"requestId\": \"provider-request-1\",\n  \"invokedFunctionArn\": \"arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-migration:43\",\n  \"functionVersion\": \"43\",\n  \"migration\": {\n    \"schemaVersion\": \"honua.migration-run/v1\",\n    \"runId\": \"62970000-0000-4000-8000-000000000001\",\n    \"outcome\": \"completed\",\n    \"provider\": \"postgres\",\n    \"schemaVerified\": false,\n    \"targetLocatorSha256\": \"33635ee2d208b8113be454ce8cb8293cdbc0014e16c14c54ca75f361163747d4\",\n    \"metadataSchema\": \"honua\",\n    \"packagedMigrationManifestSha256\": \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"\n  }\n}" }
  }
  expect_failures = [aws_lambda_invocation.migration]
}

run "failed_migration_blocks_serving_deployment" {
  command = apply
  # Runs share state: replace the prior CREATE_ONLY invocation so this
  # run must evaluate its own injected receipt instead of the earlier success.
  plan_options { replace = [aws_lambda_invocation.migration[0]] }
  override_resource {
    target = aws_lambda_invocation.migration[0]
    values = { result = "{\n  \"schemaVersion\": \"honua.lambda-migration-run/v1\",\n  \"requestId\": \"provider-request-1\",\n  \"invokedFunctionArn\": \"arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-migration:43\",\n  \"functionVersion\": \"43\",\n  \"migration\": {\n    \"schemaVersion\": \"honua.migration-run/v1\",\n    \"runId\": \"62970000-0000-4000-8000-000000000001\",\n    \"outcome\": \"failed\",\n    \"provider\": \"postgres\",\n    \"schemaVerified\": true,\n    \"targetLocatorSha256\": \"33635ee2d208b8113be454ce8cb8293cdbc0014e16c14c54ca75f361163747d4\",\n    \"metadataSchema\": \"honua\",\n    \"packagedMigrationManifestSha256\": \"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"\n  }\n}" }
  }
  expect_failures = [aws_lambda_invocation.migration]
}

run "malformed_receipt_blocks_serving_deployment" {
  command = apply
  # Runs share state: replace the prior CREATE_ONLY invocation so this
  # run must evaluate its own injected receipt instead of the earlier success.
  plan_options { replace = [aws_lambda_invocation.migration[0]] }
  override_resource {
    target = aws_lambda_invocation.migration[0]
    values = { result = "{invalid-json" }
  }
  expect_failures = [aws_lambda_invocation.migration]
}
