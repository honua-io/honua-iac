# Negative input plans use fresh state: they must not destroy settings retained
# by the positive shared-state apply scenarios in operator_contract.tftest.hcl.
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

run "whitespace_mcp_url_path_is_rejected" {
  command = plan
  variables {
    operator_contract_validation = {
      mcp_enabled        = true
      mcp_profile        = "default"
      mcp_transport      = "http"
      mcp_path           = "/bad path"
      mcp_required_tools = ["honua_get_style"]
    }
  }
  expect_failures = [var.operator_contract_validation]
}

run "non_ascii_contract_tag_name_is_rejected" {
  command = plan
  variables {
    tags = { "équipe" = "maps" }
  }
  expect_failures = [var.tags]
}

run "empty_contract_environment_is_rejected" {
  command = plan
  variables {
    environment = ""
  }
  expect_failures = [var.environment]
}

run "empty_contract_name_prefix_is_rejected" {
  command = plan
  variables {
    name_prefix = ""
  }
  expect_failures = [var.name_prefix]
}
