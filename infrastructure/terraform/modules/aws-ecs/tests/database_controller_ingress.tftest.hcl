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

  mock_data "aws_elb_service_account" {
    defaults = {
      arn = "arn:aws:iam::127311923021:root"
      id  = "127311923021"
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

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/honua-test/0000000000000000"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/honua-test/0000000000000000"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/honua-test/0000000000000000/1111111111111111"
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
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  # Recommended in Production; unset only plans with a check warning.
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  image                            = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  admin_password                   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  connection_encryption_master_key = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  existing_vpc_id             = "vpc-0123456789abcdef0"
  existing_vpc_cidr           = "10.0.0.0/16"
  existing_public_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
  existing_private_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]

  existing_db_endpoint          = ""
  existing_db_connection_string = ""
  db_password                   = "test-database-password"

  redis_enabled           = false
  kms_key_arn             = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
  alb_access_logs_enabled = false
}

run "default_database_ingress_stays_service_only" {
  command = apply
  assert {
    condition     = length(aws_security_group.rds[0].ingress) == 1 && one(aws_security_group.rds[0].ingress).security_groups == toset([aws_security_group.ecs.id])
    error_message = "No controller access may be added by default."
  }
}

run "only_selected_groups_reach_private_postgres" {
  command = apply
  variables {
    db_additional_ingress_security_group_ids = ["sg-0123456789abcdef0", "sg-01234567"]
  }
  assert {
    condition     = length(aws_security_group.rds[0].ingress) == 3 && alltrue([for rule in aws_security_group.rds[0].ingress : rule.from_port == 5432 && rule.to_port == 5432 && rule.protocol == "tcp" && length(coalesce(rule.cidr_blocks, [])) == 0 && length(coalesce(rule.ipv6_cidr_blocks, [])) == 0])
    error_message = "Private controller access must add only TCP5432 security-group rules, without CIDR ingress."
  }
  assert {
    condition     = toset(flatten([for rule in aws_security_group.rds[0].ingress : tolist(rule.security_groups)])) == setunion(var.db_additional_ingress_security_group_ids, toset([aws_security_group.ecs.id])) && !var.db_publicly_accessible
    error_message = "Database access must be exactly the selected controller and service groups and remain private."
  }
}

run "existing_database_is_not_reconfigured" {
  command = plan
  variables {
    existing_db_endpoint                     = "postgres.example.internal"
    existing_db_connection_string            = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
    db_additional_ingress_security_group_ids = ["sg-0123456789abcdef0"]
  }
  assert {
    condition     = length(aws_security_group.rds) == 0
    error_message = "The module must not create ingress for an externally managed database."
  }
}

run "reject_cidr_in_security_group_input" {
  command = plan
  variables {
    db_additional_ingress_security_group_ids = ["0.0.0.0/0"]
  }
  expect_failures = [var.db_additional_ingress_security_group_ids]
}
