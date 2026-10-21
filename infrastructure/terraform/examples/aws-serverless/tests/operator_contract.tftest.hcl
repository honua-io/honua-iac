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

  mock_data "aws_lambda_function" {
    defaults = {
      image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      role      = "arn:aws:iam::123456789012:role/honua-test"
      version   = "43"
    }
  }

  mock_resource "aws_db_proxy" {
    defaults = {
      arn      = "arn:aws:rds:us-east-1:123456789012:db-proxy:prx-0123456789abcdef0"
      endpoint = "honua.proxy.test.rds.amazonaws.com"
    }
  }

  mock_resource "aws_db_proxy_default_target_group" {
    defaults = { name = "default" }
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
      api_endpoint  = "https://abcdefghij.execute-api.us-east-1.amazonaws.com"
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

# Provider-mocked apply of the actual customer-facing root. No AWS calls.
variables {
  region               = "us-east-1"
  name_prefix          = "honua-contract"
  environment          = "dev"
  lambda_alias_version = "43"
  honua_image_uri      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"
  # checkov:skip=CKV_SECRET_6: Synthetic test-only database password.
  db_password                = "Synthetic-Terraform-Test-Db-4721aA1"
  redis_enabled              = false
  enable_postgis             = false
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
  operator_contract_identity = {
    candidate_digest      = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    manifest_digest       = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    iac_revision          = "cccccccccccccccccccccccccccccccccccccccc"
    terraform_version     = "1.11.4"
    provider_lock_digest  = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    image_reference       = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    image_digest          = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    backend_config_digest = "9999999999999999999999999999999999999999999999999999999999999999"
    state_lineage         = "11111111-2222-3333-4444-555555555555"
    state_serial          = 7
    workload_identity     = "arn:aws:iam::123456789012:role/honua-test"
  }
}

run "unqualified_development_contract" {
  command = apply
  variables {
    operator_contract_identity = null
    lambda_alias_name          = "${join("", [for _ in range(127) : "a"])}b"
  }
  override_resource {
    target = module.honua.aws_lambda_alias.live
    values = {
      arn        = "arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"
      invoke_arn = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab/invocations"
    }
  }
  assert {
    condition     = output.operator_contract_status == "unqualified" && length(data.aws_lambda_function.operator_contract_alias) == 0
    error_message = "Development output must stay unqualified and must not resolve a caller's missing image identity."
  }
  assert {
    condition     = length(output.runtime_binding_contract.targetId) == 128 && output.control_plane_target_id == output.runtime_binding_contract.targetId && output.runtime_binding_contract.resourceIdentity.aliasArn == "arn:aws:lambda:us-east-1:123456789012:function:honua-contract-dev-honua:${join("", [for _ in range(127) : "a"])}b"
    error_message = "The actual customer-root output for a valid long alias must keep the bounded handoff and control-plane IDs joined without replacing the alias ARN."
  }
}

run "qualified_lambda_contract" {
  command = apply
  variables {
    retained_runtime_settings_documents = {
      (run.unqualified_development_contract.runtime_settings_retention_entry.hash) = run.unqualified_development_contract.runtime_settings_retention_entry.document
    }
  }
  assert {
    condition = (
      output.operator_contract_status == "qualified" &&
      output.deployment_contract.stack.id == "aws-lambda" &&
      output.deployment_contract.stack.runtime == "lambda" &&
      output.deployment_contract.rollout.backend_name == "honua-gitops-aws-lambda" &&
      output.deployment_contract.workload.cluster_id == null &&
      output.deployment_contract.rollout.canary.enabled == false
    )
    error_message = "The ordinary root must project its actual Lambda workload, with no ECS/canary fixture."
  }
  assert {
    condition = (
      output.deployment_contract.rollout.current_revision == "43" &&
      output.deployment_contract.rollout.desired_revision == "43" &&
      data.aws_lambda_function.operator_contract_alias[0].qualifier == "43"
    )
    error_message = "Immutable image/role checks must query the serving alias version that is selected for the current deployment."
  }
  assert {
    condition = (
      output.deployment_contract.identity == output.validation_contract.identity &&
      output.deployment_contract.identity == output.operations_contract.identity &&
      output.operator_contract_digest == sha256(jsonencode({
        schema_version      = "honua.operator-contract/v2"
        deployment_contract = merge(output.deployment_contract, { identity = { for key, value in output.deployment_contract.identity : key => value if key != "contract_digest" } })
        validation_contract = merge(output.validation_contract, { identity = { for key, value in output.validation_contract.identity : key => value if key != "contract_digest" } })
        operations_contract = merge(output.operations_contract, { identity = { for key, value in output.operations_contract.identity : key => value if key != "contract_digest" } })
      }))
    )
    error_message = "All three identities and the digest over their canonical bytes must agree."
  }
  assert {
    condition = (
      output.deployment_contract.secret_refs.admin_password == output.operations_contract.secrets.references.admin_password.id &&
      !strcontains(jsonencode(output.operator_contract), var.honua_admin_password) &&
      !strcontains(jsonencode(output.operator_contract), var.db_password) &&
      !contains(keys(output.operator_contract), "observation")
    )
    error_message = "Contract output must contain secret references, not credentials or a fabricated live observation."
  }
}

run "configured_public_origin_projects_without_retargeting_ingress" {
  command = apply
  variables {
    public_base_url            = "https://maps.example.com/honua"
    operator_contract_identity = null
    retained_runtime_settings_documents = {
      (run.unqualified_development_contract.runtime_settings_retention_entry.hash) = run.unqualified_development_contract.runtime_settings_retention_entry.document
      (run.qualified_lambda_contract.runtime_settings_retention_entry.hash)        = run.qualified_lambda_contract.runtime_settings_retention_entry.document
    }
  }
  assert {
    condition = (
      output.deployment_contract.endpoints.public_base_url == "https://maps.example.com/honua" &&
      output.validation_contract.tests.readiness_url == "https://maps.example.com/honua/healthz/ready" &&
      output.validation_contract.tests.admin_url == "https://maps.example.com/honua/api/v1/admin" &&
      output.validation_contract.tests.protocol_url == "https://maps.example.com/honua/v1" &&
      output.deployment_contract.dependencies.ingress.endpoint == module.honua.service_url &&
      output.deployment_contract.endpoints.ingress_dns_name == replace(module.honua.service_url, "https://", "")
    )
    error_message = "The public handoff and validation URLs must use Public__BaseUrl while the ingress remains the API Gateway URL."
  }
}

run "older_alias_cannot_claim_current_dependency_settings" {
  # The precondition is already decidable during planning after the positive run.
  command = plan
  variables {
    lambda_alias_version = "42"
    retained_runtime_settings_documents = {
      (run.unqualified_development_contract.runtime_settings_retention_entry.hash) = run.unqualified_development_contract.runtime_settings_retention_entry.document
      (run.qualified_lambda_contract.runtime_settings_retention_entry.hash)        = run.qualified_lambda_contract.runtime_settings_retention_entry.document
    }
  }
  expect_failures = [output.deployment_contract]
}

run "serving_alias_image_mismatch_refused" {
  # The precondition is already decidable during planning after the positive run.
  command = plan
  variables {
    retained_runtime_settings_documents = {
      (run.unqualified_development_contract.runtime_settings_retention_entry.hash) = run.unqualified_development_contract.runtime_settings_retention_entry.document
      (run.qualified_lambda_contract.runtime_settings_retention_entry.hash)        = run.qualified_lambda_contract.runtime_settings_retention_entry.document
    }
  }
  override_data {
    target = data.aws_lambda_function.operator_contract_alias[0]
    values = {
      image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      role      = "arn:aws:iam::123456789012:role/honua-test"
    }
  }
  expect_failures = [output.deployment_contract]
}

run "serving_alias_role_mismatch_refused" {
  # The precondition is already decidable during planning after the positive run.
  command = plan
  variables {
    retained_runtime_settings_documents = {
      (run.unqualified_development_contract.runtime_settings_retention_entry.hash) = run.unqualified_development_contract.runtime_settings_retention_entry.document
      (run.qualified_lambda_contract.runtime_settings_retention_entry.hash)        = run.qualified_lambda_contract.runtime_settings_retention_entry.document
    }
  }
  override_data {
    target = data.aws_lambda_function.operator_contract_alias[0]
    values = {
      image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      role      = "arn:aws:iam::123456789012:role/some-other-role"
    }
  }
  expect_failures = [output.deployment_contract]
}

run "marketplace_image_override_cannot_bypass_identity" {
  # The precondition is already decidable during planning after the positive run.
  command = plan
  variables {
    install = { artifact = { image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" } }
    retained_runtime_settings_documents = {
      (run.unqualified_development_contract.runtime_settings_retention_entry.hash) = run.unqualified_development_contract.runtime_settings_retention_entry.document
      (run.qualified_lambda_contract.runtime_settings_retention_entry.hash)        = run.qualified_lambda_contract.runtime_settings_retention_entry.document
    }
  }
  expect_failures = [output.deployment_contract]
}

run "proxy_and_shared_storage_are_real_runtime_dependencies" {
  command = apply
  variables {
    enable_rds_proxy                = true
    file_storage_provider           = "AwsS3"
    file_storage_aws_s3_bucket_name = "honua-contract-files"
    file_storage_aws_s3_key_prefix  = "imports/"
    retained_runtime_settings_documents = {
      (run.unqualified_development_contract.runtime_settings_retention_entry.hash) = run.unqualified_development_contract.runtime_settings_retention_entry.document
      (run.qualified_lambda_contract.runtime_settings_retention_entry.hash)        = run.qualified_lambda_contract.runtime_settings_retention_entry.document
    }
  }
  override_resource {
    target = module.honua.aws_secretsmanager_secret.proxy_connection_string[0]
    values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:proxy-connection-AbCdEf" }
  }
  assert {
    condition = (
      output.deployment_contract.dependencies.database.endpoint == "honua.proxy.test.rds.amazonaws.com" &&
      output.deployment_contract.dependencies.database.secret_ref == module.honua.runtime_db_connection_secret_arn &&
      output.deployment_contract.secret_refs.db_connection == module.honua.runtime_db_connection_secret_arn &&
      output.operations_contract.secrets.references.db_connection.id == module.honua.runtime_db_connection_secret_arn &&
      output.deployment_contract.secret_refs.db_connection != output.migrate_db_connection_secret_arn
    )
    error_message = "Runtime contracts must use the actual proxy endpoint/secret while migration retains the direct connection."
  }
  assert {
    condition = output.deployment_contract.dependencies.object_storage == {
      kind = "aws-s3", enabled = true, bucket = "honua-contract-files", prefix = "imports/"
    }
    error_message = "Shared S3 storage must be projected from the configured runtime storage, not a certification artifact bucket."
  }
}

run "external_database_is_not_claimed_as_managed" {
  command = apply
  variables {
    existing_db_endpoint          = "external-db.example.test"
    existing_db_connection_string = "Host=external-db.example.test;Database=honua;Username=test;Password=synthetic-only"
    retained_runtime_settings_documents = {
      (run.unqualified_development_contract.runtime_settings_retention_entry.hash) = run.unqualified_development_contract.runtime_settings_retention_entry.document
      (run.qualified_lambda_contract.runtime_settings_retention_entry.hash)        = run.qualified_lambda_contract.runtime_settings_retention_entry.document
    }
  }
  assert {
    condition = (
      output.deployment_contract.dependencies.database.managed == false &&
      output.deployment_contract.dependencies.database.kind == "postgres" &&
      output.deployment_contract.dependencies.database.endpoint == "external-db.example.test" &&
      output.validation_contract.platform.capabilities.backup_drill == false &&
      output.validation_contract.test_data.reuse_data_stack == true &&
      !strcontains(jsonencode(output.operator_contract), "synthetic-only")
    )
    error_message = "Reused databases must retain external ownership without leaking the supplied connection string."
  }
}

run "fractional_state_serial_is_rejected_before_contract_projection" {
  command = plan
  variables {
    operator_contract_identity = {
      candidate_digest      = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      manifest_digest       = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      iac_revision          = "cccccccccccccccccccccccccccccccccccccccc"
      terraform_version     = "1.11.4"
      provider_lock_digest  = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      image_reference       = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      image_digest          = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      backend_config_digest = "9999999999999999999999999999999999999999999999999999999999999999"
      state_lineage         = "11111111-2222-3333-4444-555555555555"
      state_serial          = 1.5
      workload_identity     = "arn:aws:iam::123456789012:role/honua-test"
    }
  }
  expect_failures = [var.operator_contract_identity]
}

run "fractional_ttl_is_rejected_before_contract_projection" {
  command = plan
  variables {
    operator_contract_validation = { ttl_hours = 1.5 }
  }
  expect_failures = [var.operator_contract_validation]
}

run "empty_validation_tenant_prefix_is_rejected" {
  command = plan
  variables {
    operator_contract_validation = { tenant_prefix = "" }
  }
  expect_failures = [var.operator_contract_validation]
}

run "whitespace_validation_tenant_prefix_is_rejected" {
  command = plan
  variables {
    operator_contract_validation = { tenant_prefix = "  " }
  }
  expect_failures = [var.operator_contract_validation]
}

run "blank_mcp_tool_is_rejected" {
  command = plan
  variables {
    operator_contract_validation = {
      mcp_enabled        = true
      mcp_profile        = "default"
      mcp_transport      = "http"
      mcp_path           = "/mcp"
      mcp_required_tools = ["honua_get_style", "  "]
    }
  }
  expect_failures = [var.operator_contract_validation]
}

run "empty_mcp_tool_is_rejected" {
  command = plan
  variables {
    operator_contract_validation = {
      mcp_enabled        = true
      mcp_profile        = "default"
      mcp_transport      = "http"
      mcp_path           = "/mcp"
      mcp_required_tools = [""]
    }
  }
  expect_failures = [var.operator_contract_validation]
}
