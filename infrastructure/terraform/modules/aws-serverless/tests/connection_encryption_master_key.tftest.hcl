# Connection-encryption master key reach (honua-release e2e-cloud-aws run
# 38066103745, aws-serverless redis-on with control-plane events and GP Batch).
#
# Every process that composes the server DI from local.lambda_environment
# resolves Security__ConnectionEncryption__MasterKey from Secrets Manager at
# startup. The control-plane event functions (reconcile, backstop, tick) run
# with that environment but their role could not read the master-key secret, so
# all three crashed at init with "Failed to resolve the security setting
# 'Security:ConnectionEncryption:MasterKey' from AWS Secrets Manager"
# (AccessDeniedException, HTTP 400). Their role must read exactly the API role's
# secret set.
#
# Each secret gets a distinct ARN here: the shared mock default would make the
# master-key and admin-password secrets indistinguishable.

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

override_resource {
  target = aws_secretsmanager_secret.connection_string
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test/connection-string-Ab12Cd" }
}
override_resource {
  target = aws_secretsmanager_secret.admin_password
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test/admin-password-Ab12Cd" }
}
override_resource {
  target = aws_secretsmanager_secret.master_key
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test/connection-encryption-master-key-Ab12Cd" }
}
override_resource {
  target = aws_secretsmanager_secret.redis_connection
  values = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test/redis-connection-Ab12Cd" }
}

variables {
  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"

  # ElastiCache validates the auth token in-provider and the random provider is
  # mocked here, so supply one explicitly instead of auto-generating it.
  redis_auth_token = "aaaaAAAA1111&&&&aaaaAAAA1111&&&&"

  # The failing cell's shape: Redis on, key ring and audit chain key set,
  # control-plane events and GP Batch enabled.
  redis_enabled                             = true
  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  audit_chain_key_secret_arn                = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
  enable_control_plane_events               = true
  enable_gp_batch                           = true
}

run "control_plane_event_role_reads_the_api_secret_set" {
  command = apply

  assert {
    condition = contains(
      flatten([for s in jsondecode(aws_iam_role_policy.control_plane_events[0].policy).Statement : s.Resource if contains(s.Action, "secretsmanager:GetSecretValue")]),
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test/connection-encryption-master-key-Ab12Cd"
    )
    error_message = "The control-plane event role must read the connection-encryption master-key secret its environment references."
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.control_plane_events[0].policy).Statement : s.Resource if contains(s.Action, "secretsmanager:GetSecretValue")
      ])) == toset(flatten([
      for s in jsondecode(aws_iam_policy.lambda_secrets.policy).Statement : s.Resource if contains(s.Action, "secretsmanager:GetSecretValue")
    ]))
    error_message = "The control-plane event role must read exactly the secrets the API Lambda role reads."
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_policy.lambda_secrets.policy).Statement : s.Resource if contains(s.Action, "secretsmanager:GetSecretValue")
      ])) == toset([
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test/connection-string-Ab12Cd",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test/admin-password-Ab12Cd",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test/connection-encryption-master-key-Ab12Cd",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test/redis-connection-Ab12Cd",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123",
    ])
    error_message = "The API Lambda role must read the connection string, admin password, master key, Redis, key-ring and audit-chain secrets."
  }

  assert {
    condition = alltrue([
      for fn in [aws_lambda_function.control_plane_reconcile[0], aws_lambda_function.control_plane_backstop[0], aws_lambda_function.control_plane_tick[0]] :
      fn.environment[0].variables["Security__ConnectionEncryption__MasterKey"] == aws_lambda_function.this.environment[0].variables["Security__ConnectionEncryption__MasterKey"]
    ])
    error_message = "Every control-plane event function must reference the API's master-key secret."
  }
}

# The GP Batch worker derived its master key from the ADMIN PASSWORD secret, so
# it could not decrypt connection secrets the API encrypted with the master key.
run "gp_batch_job_uses_and_reads_the_master_key" {
  command = apply

  assert {
    condition = alltrue([
      for tier, jd in aws_batch_job_definition.gp :
      one([for e in jsondecode(jd.container_properties).environment : e.value if e.name == "Security__ConnectionEncryption__MasterKey"]) == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test/connection-encryption-master-key-Ab12Cd"
    ])
    error_message = "Every GP job-definition tier must reference the connection-encryption master-key secret, not the admin password."
  }

  assert {
    condition = contains(
      flatten([for s in jsondecode(aws_iam_role_policy.batch_job_secrets[0].policy).Statement : s.Resource if contains(s.Action, "secretsmanager:GetSecretValue")]),
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test/connection-encryption-master-key-Ab12Cd"
    )
    error_message = "The GP job role must be able to read the master-key secret its job definition references."
  }
}
