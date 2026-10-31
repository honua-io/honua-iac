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

run "console_routes_and_auth" {
  command = plan
  variables {
    domain_name         = "cell.example.com"
    alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    generic_oidc = {
      authority         = "https://issuer.example.com"
      client_id         = "client"
      client_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:oidc-AbC123"
    }
    operator_bearer = {
      signing_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:bearer-AbC123"
    }
    console = {
      image               = "ghcr.io/honua-io/honua-console@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      oauth2_proxy_image  = "example.com/oauth@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      header_filter_image = "example.com/nginx@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      cookie_secret_arn   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:cookie-AbC123"
      email_domain        = "example.com"
    }
  }
  assert {
    condition     = length(aws_lb_listener_rule.console) == length(local.console_paths) && alltrue([for paths in local.console_paths : length(paths) <= 3]) && contains(flatten(local.console_paths), "/admin/auth/callback")
    error_message = "Console routes and server callback must reach the edge."
  }
  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.console[0].container_definitions)) == 3 && jsondecode(aws_ecs_task_definition.console[0].container_definitions)[0].environment[1].value == "https://cell.example.com"
    error_message = "Console must bind to the public server origin behind the identity edge."
  }
  assert {
    condition = alltrue([
      contains([for e in jsondecode(aws_ecs_task_definition.console[0].container_definitions)[0].environment : "${e.name}=${e.value}"], "Honua__Console__Auth__Mode=EdgeForwarded"),
      contains([for e in jsondecode(aws_ecs_task_definition.console[0].container_definitions)[0].environment : "${e.name}=${e.value}"], "Honua__Console__Auth__EdgeForwarded__ServerSessionIssuer=https://issuer.example.com"),
      strcontains(jsondecode(aws_ecs_task_definition.console[0].container_definitions)[1].command[0], "proxy_set_header X-Forwarded-Access-Token"),
      contains([for e in jsondecode(aws_ecs_task_definition.console[0].container_definitions)[2].secrets : e.name], "OAUTH2_PROXY_COOKIE_SECRET")
    ])
    error_message = "Console must bind edge identity to the server issuer and strip the edge token."
  }

}
run "console_rejects_missing_identity" {
  command = plan
  variables {
    console = {
      image               = "ghcr.io/honua-io/honua-console@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      oauth2_proxy_image  = "example.com/oauth@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      header_filter_image = "example.com/nginx@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      cookie_secret_arn   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:cookie-AbC123"
      email_domain        = "example.com"
    }
  }
  expect_failures = [terraform_data.console]
}
