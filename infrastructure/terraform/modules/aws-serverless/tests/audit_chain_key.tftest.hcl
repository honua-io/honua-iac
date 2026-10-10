# Audit hash-chain key on Lambda (AuditLog:ChainVerification:Key).
#
# Every process that appends audit rows must carry the same key: the API function, the
# control-plane event functions (they share its environment) and the GP Batch jobs. Lambda cannot
# resolve Secrets Manager into env, so each receives an aws:secretsmanager: REFERENCE the server
# resolves at startup with its own role, never the value. The key is recommended, not required:
# without it audit rows are still written but chain verification never succeeds, so planning warns.

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

  # Control-plane event targets and schedules validate these ARNs in-provider.
  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:us-east-1:123456789012:function:honua-mock"
    }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/honua-mock"
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
  redis_enabled  = false
}

run "unset_audit_chain_key_warns" {
  command         = plan
  expect_failures = [check.audit_chain_key_configured]
}

run "unset_audit_chain_key_requests_nothing" {
  command = apply

  variables {
    enable_gp_batch = true
  }

  expect_failures = [check.audit_chain_key_configured]

  assert {
    condition     = !contains(keys(aws_lambda_function.this.environment[0].variables), "AuditLog__ChainVerification__Key")
    error_message = "Without an ARN the function must not carry an audit-chain key reference."
  }

  assert {
    condition     = !contains([for e in jsondecode(aws_batch_job_definition.gp["s"].container_properties).environment : e.name], "AuditLog__ChainVerification__Key")
    error_message = "Without an ARN the GP job must not carry an audit-chain key reference."
  }
}

run "every_audit_writer_gets_the_same_reference_and_grant" {
  command = apply

  variables {
    enable_gp_batch                    = true
    enable_control_plane_events        = true
    audit_chain_key_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
    audit_chain_key_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000003"
  }

  assert {
    condition = alltrue([
      # Lambda carries the same-account, same-region secret by NAME (4 KB environment cap).
      aws_lambda_function.this.environment[0].variables["AuditLog__ChainVerification__Key"] == "aws:secretsmanager:operator-audit-chain",
      aws_lambda_function.control_plane_reconcile[0].environment[0].variables["AuditLog__ChainVerification__Key"] == "aws:secretsmanager:operator-audit-chain",
      one([for e in jsondecode(aws_batch_job_definition.gp["s"].container_properties).environment : e.value if e.name == "AuditLog__ChainVerification__Key"]) == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123",
    ])
    error_message = "API, event and GP processes must all carry the same audit-chain key reference, never the value."
  }

  assert {
    condition = alltrue([
      contains(flatten([for s in jsondecode(aws_iam_policy.lambda_secrets.policy).Statement : s.Resource if contains(s.Action, "secretsmanager:GetSecretValue")]), "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"),
      contains(one([for s in jsondecode(aws_iam_role_policy.control_plane_events[0].policy).Statement : s.Resource if s.Sid == "ReadHonuaSecrets"]), "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"),
      contains(flatten([for s in jsondecode(aws_iam_role_policy.batch_job_secrets[0].policy).Statement : s.Resource if contains(s.Action, "secretsmanager:GetSecretValue")]), "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"),
    ])
    error_message = "Every role that resolves the reference must be able to read the audit-chain key secret."
  }

  assert {
    condition = alltrue([
      contains(flatten([for s in jsondecode(aws_iam_policy.lambda_secrets.policy).Statement : s.Resource if contains(s.Action, "kms:Decrypt")]), "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000003"),
      contains(flatten([for s in jsondecode(aws_iam_role_policy.batch_job_secrets[0].policy).Statement : s.Resource if contains(s.Action, "kms:Decrypt")]), "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000003"),
    ])
    error_message = "A customer-managed key for the audit-chain secret must be granted to the function and job roles."
  }

  assert {
    condition     = output.audit_chain_key_secret_arn == "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
    error_message = "The module must expose the audit-chain key secret for the deploy contract."
  }
}

run "reject_plain_audit_chain_key" {
  command = plan

  variables {
    # checkov:skip=CKV_SECRET_6: A synthetic all-zero base64 value proving key material is rejected, not a credential.
    audit_chain_key_secret_arn = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  }

  expect_failures = [var.audit_chain_key_secret_arn]
}

run "reject_audit_chain_key_wildcard" {
  command = plan

  variables {
    audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-*"
  }

  expect_failures = [var.audit_chain_key_secret_arn]
}

run "reject_audit_chain_key_environment" {
  command = plan

  variables {
    audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
    additional_env             = { "auditlog:chainverification:key" = "plaintext" }
  }

  expect_failures = [var.additional_env]
}
