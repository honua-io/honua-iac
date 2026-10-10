# GP Batch worker parity with the Lambda for Redis and the operation key-ring
# certificate (honua-release e2e-cloud-aws run 38038435904, aws-serverless/redis-on).
#
# The GP worker runs the same server image and reports job state through the
# same durable Redis job store as the Lambda. Without ConnectionStrings__redis
# the worker logs "No Redis is configured" and the job stays "running" forever;
# with Redis connected the server refuses to start in Production unless the
# key-ring certificate is configured, so the two must travel together. Both are
# aws:secretsmanager: REFERENCES resolved with the job role, never values, and
# Redis-off cells carry neither.

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
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password = "Synthetic-Terraform-Test-Admin-4721!aA1"

  # ElastiCache validates the auth token in-provider and the random provider is
  # mocked here, so supply one explicitly instead of auto-generating it.
  redis_auth_token = "aaaaAAAA1111&&&&aaaaAAAA1111&&&&"

  enable_gp_batch = true
}

run "redis_on_gp_job_carries_redis_and_key_ring_references" {
  command = apply

  variables {
    redis_enabled                                     = true
    operation_key_ring_certificate_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    operation_key_ring_certificate_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"
  }

  assert {
    condition = alltrue([
      for tier, jd in aws_batch_job_definition.gp :
      # Same secret: the job definition by ARN, the Lambda by name (4 KB environment cap).
      one([for e in jsondecode(jd.container_properties).environment : e.value if e.name == "ConnectionStrings__redis"]) == "aws:secretsmanager:${aws_secretsmanager_secret.redis_connection[0].arn}"
    ])
    error_message = "Every GP job-definition tier must carry the same ConnectionStrings__redis reference as the Lambda."
  }

  assert {
    condition     = aws_lambda_function.this.environment[0].variables["ConnectionStrings__redis"] == "aws:secretsmanager:${aws_secretsmanager_secret.redis_connection[0].name}"
    error_message = "The Lambda must reference the same Redis secret, by name."
  }

  assert {
    condition = alltrue([
      for tier, jd in aws_batch_job_definition.gp :
      startswith(one([for e in jsondecode(jd.container_properties).environment : e.value if e.name == "ConnectionStrings__redis"]), "aws:secretsmanager:")
    ])
    error_message = "The GP job must receive Redis as an aws:secretsmanager: reference, never the connection string."
  }

  assert {
    condition = alltrue([
      for tier, jd in aws_batch_job_definition.gp :
      one([for e in jsondecode(jd.container_properties).environment : e.value if e.name == "Operations__SecretChannel__KeyRingCertificatePkcs12"]) == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    ])
    error_message = "Every GP job-definition tier must carry the key-ring certificate reference a Redis-connected server requires."
  }

  assert {
    condition = contains(
      flatten([for s in jsondecode(aws_iam_role_policy.batch_job_secrets[0].policy).Statement : s.Resource if contains(s.Action, "secretsmanager:GetSecretValue")]),
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    )
    error_message = "The GP job role must be able to read the key-ring certificate secret."
  }

  assert {
    condition = contains(
      flatten([for s in jsondecode(aws_iam_role_policy.batch_job_secrets[0].policy).Statement : s.Resource if contains(s.Action, "kms:Decrypt")]),
      "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"
    )
    error_message = "A customer-managed key for the key-ring certificate must be granted to the GP job role."
  }

  assert {
    condition     = length([for e in aws_security_group.batch[0].egress : e if e.from_port == 6379 && e.to_port == 6379]) == 1
    error_message = "The GP Batch security group must allow egress to Redis."
  }

  assert {
    condition     = contains(flatten([for i in aws_security_group.redis[0].ingress : i.security_groups if i.from_port == 6379]), aws_security_group.batch[0].id)
    error_message = "The module-managed Redis security group must admit the GP Batch security group."
  }
}

run "redis_off_gp_job_carries_neither" {
  command = apply

  variables {
    redis_enabled                             = false
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }

  assert {
    condition = alltrue([
      for tier, jd in aws_batch_job_definition.gp : length([
        for e in jsondecode(jd.container_properties).environment : e
        if contains(["ConnectionStrings__redis", "Operations__SecretChannel__KeyRingCertificatePkcs12"], e.name)
      ]) == 0
    ])
    error_message = "Redis-off GP jobs must carry neither a Redis nor a key-ring certificate reference."
  }

  assert {
    condition = !contains(
      flatten([for s in jsondecode(aws_iam_role_policy.batch_job_secrets[0].policy).Statement : s.Resource]),
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    )
    error_message = "Redis-off must not grant the GP job role read on the unused certificate secret."
  }

  assert {
    condition     = length([for e in aws_security_group.batch[0].egress : e if e.from_port == 6379]) == 0
    error_message = "Redis-off must not open Redis egress from the GP Batch security group."
  }
}
