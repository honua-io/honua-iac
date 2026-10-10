# Operation policy rules (operations_policy_rules).
#
# The server image runs in Production, whose appsettings enable
# Operations:Policy with DefaultDecision Deny, so every typed operation (for
# example service.publish) is denied until the operator authors rules. The
# module renders the rules as indexed Operations__Policy__Rules__<n>__<Field>
# entries on the primary and canary containers; unset optional fields render
# nothing.

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

  existing_db_endpoint          = "postgres.example.internal"
  existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"

  redis_enabled           = false
  kms_key_arn             = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
  alb_access_logs_enabled = false
}

run "no_rules_render_nothing" {
  command = plan

  assert {
    condition     = length([for e in concat(local.primary_container_environment, local.canary_container_environment) : e if startswith(e.name, "Operations__Policy__")]) == 0
    error_message = "With no rules the containers must carry no Operations__Policy__ entries."
  }
}

run "rules_render_on_primary_and_canary" {
  # apply: the rendered container definitions embed secret ARNs that are
  # unknown at plan time.
  command = apply

  variables {
    # A canary runs a second task, which needs the multi-node topology.
    canary_enabled                            = true
    deployment_mode                           = "MultiNode"
    file_storage_provider                     = "AwsS3"
    file_storage_aws_s3_bucket_name           = "honua-test-files"
    redis_enabled                             = true
    redis_auth_token                          = "aA1aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    operations_policy_rules = [
      {
        operation_id = "service.publish"
        role         = "publisher"
        decision     = "Allow"
      },
      {
        operation_id  = "*"
        role          = "operator"
        tier          = "enterprise"
        decision      = "RequireApproval"
        reason        = "Operator changes need a second reviewer."
        approval_lane = "ops-review"
      },
    ]
  }

  assert {
    condition = alltrue([
      for environment in [local.primary_container_environment, local.canary_container_environment] :
      { for e in environment : e.name => e.value if startswith(e.name, "Operations__Policy__") } == {
        Operations__Policy__Rules__0__OperationId  = "service.publish"
        Operations__Policy__Rules__0__Role         = "publisher"
        Operations__Policy__Rules__0__Decision     = "Allow"
        Operations__Policy__Rules__1__OperationId  = "*"
        Operations__Policy__Rules__1__Role         = "operator"
        Operations__Policy__Rules__1__Tier         = "enterprise"
        Operations__Policy__Rules__1__Decision     = "RequireApproval"
        Operations__Policy__Rules__1__Reason       = "Operator changes need a second reviewer."
        Operations__Policy__Rules__1__ApprovalLane = "ops-review"
      }
    ])
    error_message = "Primary and canary containers must carry exactly the flattened rules, in order, omitting unset fields."
  }

  assert {
    condition = alltrue([
      for definition in [aws_ecs_task_definition.this, aws_ecs_task_definition.canary[0]] :
      one([for e in jsondecode(definition.container_definitions)[0].environment : e.value if e.name == "Operations__Policy__Rules__0__OperationId"]) == "service.publish"
    ])
    error_message = "The rendered task definitions must carry the policy rules."
  }
}

run "operation_id_defaults_to_any_operation" {
  command = plan

  variables {
    operations_policy_rules = [{ decision = "Deny", role = "viewer" }]
  }

  assert {
    condition     = one([for e in local.primary_container_environment : e.value if e.name == "Operations__Policy__Rules__0__OperationId"]) == "*"
    error_message = "An omitted operation_id must render as the \"*\" wildcard."
  }
}

run "unknown_decision_is_rejected" {
  command = plan

  variables {
    operations_policy_rules = [{ operation_id = "service.publish", decision = "Permit" }]
  }

  expect_failures = [var.operations_policy_rules]
}
