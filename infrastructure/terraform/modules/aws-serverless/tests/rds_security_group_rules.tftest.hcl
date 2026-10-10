# The RDS security group carries no inline rules.
#
# Terraform does not support inline ingress/egress on a security group that
# also has standalone aws_security_group_rule resources: the inline set is
# authoritative, so an apply strips the standalone rules (rds_from_batch from
# #228, the custom-code phase rules) and the next one re-adds them. Every RDS
# rule is therefore standalone, and the Lambda, GP Batch and runner-CIDR rules
# must all still exist.

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

  redis_enabled               = false
  enable_gp_batch             = true
  db_additional_ingress_cidrs = ["203.0.113.10/32", "198.51.100.0/24"]
}

run "rds_rules_are_standalone_and_complete" {
  command = apply

  assert {
    condition     = length(aws_security_group.rds[0].ingress) == 0 && length(aws_security_group.rds[0].egress) == 0
    error_message = "The RDS security group must declare no inline ingress or egress; its rules are standalone aws_security_group_rule resources."
  }

  assert {
    condition = (
      aws_security_group_rule.rds_from_lambda[0].security_group_id == aws_security_group.rds[0].id &&
      aws_security_group_rule.rds_from_lambda[0].source_security_group_id == aws_security_group.lambda.id &&
      aws_security_group_rule.rds_from_lambda[0].from_port == 5432
    )
    error_message = "The Lambda must still reach PostgreSQL on the RDS security group."
  }

  assert {
    condition = (
      aws_security_group_rule.rds_from_batch[0].security_group_id == aws_security_group.rds[0].id &&
      aws_security_group_rule.rds_from_batch[0].source_security_group_id == aws_security_group.batch[0].id
    )
    error_message = "GP Batch tasks must still reach PostgreSQL on the RDS security group."
  }

  assert {
    condition = (
      toset(keys(aws_security_group_rule.rds_from_cidrs)) == toset(["203.0.113.10/32", "198.51.100.0/24"]) &&
      alltrue([for cidr, rule in aws_security_group_rule.rds_from_cidrs : tolist(rule.cidr_blocks) == tolist([cidr]) && rule.security_group_id == aws_security_group.rds[0].id])
    )
    error_message = "Every db_additional_ingress_cidrs entry (the PostGIS runner path) must keep its own PostgreSQL rule."
  }
}

run "existing_database_creates_no_rds_rules" {
  command = plan

  variables {
    enable_gp_batch               = false
    existing_db_endpoint          = "postgres.example.internal"
    existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
  }

  assert {
    condition     = length(aws_security_group.rds) == 0 && length(aws_security_group_rule.rds_from_lambda) == 0 && length(aws_security_group_rule.rds_from_cidrs) == 0
    error_message = "With an existing database the module must create no RDS security group or rules."
  }
}
