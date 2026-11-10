# The rc.2 overlay itself, planned with mocked providers. Run with the preset:
#   terraform test -var-file=presets/rc2.tfvars.example -filter=tests/rc2_preset.tftest.hcl
# Only customer inputs are set here, so every asserted value comes from the preset.

mock_provider "aws" {
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:123456789012:cluster/honuaecs-it-cluster" }
  }

  mock_data "aws_iam_role" {
    defaults = {
      name = "retained-controller"
      arn  = "arn:aws:iam::123456789012:role/retained-controller"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test-123456" }
  }
  mock_resource "aws_lb_listener_rule" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener-rule/app/honua-test/0000000000000000/1111111111111111/2222222222222222"
    }
  }

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

mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  }
}
mock_provider "null" {}

variables {
  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  audit_chain_key_secret_arn                = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
  honua_image                               = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  postgis_bootstrap_image                   = "docker.io/library/postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  honua_admin_password                      = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_connection_encryption_master_key    = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  db_password                               = "cccccccccccccccccccccccccccccccc"

  existing_vpc_id             = "vpc-0123456789abcdef0"
  existing_vpc_cidr           = "10.0.0.0/16"
  existing_public_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
  existing_private_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]

  domain_name         = "maps.example.com"
  alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  cdn = {
    viewer_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  }
  static_console = {
    viewer_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    bundle_version         = "rc.2"
  }
}

run "rc2_preset_surge_capacity_fits_the_database" {
  command = plan

  assert {
    condition     = var.desired_count >= 2 && var.max_capacity > var.desired_count && var.deployment_mode == "MultiNode"
    error_message = "The rc.2 preset keeps at least two tasks and leaves room to scale out."
  }
  assert {
    condition     = var.autoscaling_requests_per_target != null
    error_message = "The rc.2 preset scales on request count as well as CPU."
  }
  assert {
    condition     = output.db_connection_budget.source == "derived" && output.db_connection_budget.max_processes == var.max_capacity * 2
    error_message = "The pool must be derived for the maximum task count, doubled for a rolling deployment."
  }
  assert {
    condition     = output.db_connection_budget.pool_size >= 10 && output.db_connection_budget.worst_case_connections <= output.db_connection_budget.usable_connections
    error_message = "At the preset's maximum task count each pool needs at least ten connections within the database's usable connections; raise db_instance_class or lower max_capacity."
  }
}
