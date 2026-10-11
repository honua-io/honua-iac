# Public:BaseUrl on a customer domain (honua-io/honua-release#450, #282).
#
# honua-server builds absolute links (publication URLs, OGC/STAC self links,
# admin OIDC redirect URIs) only from Public:BaseUrl / PUBLIC_BASE_URL and
# falls back to a loopback origin without it; admin OIDC refuses to start
# outside Development. Customers run Honua on their own domains, so the module
# must set Public__BaseUrl=https://<domain_name> whenever the ALB serves HTTPS
# on a custom domain, on any TLD, with an explicit public_base_url override and
# without overriding a value the operator already put in additional_env.
# Mocked providers; no AWS calls.

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

run "no_domain_sets_no_public_base_url" {
  command = plan

  assert {
    condition     = !contains([for e in local.primary_container_environment : e.name], "Public__BaseUrl") && output.public_base_url == null
    error_message = "Without a custom domain or public_base_url the module must not set Public__BaseUrl."
  }
}

run "customer_domain_with_operator_certificate_sets_public_base_url" {
  command = plan

  variables {
    domain_name         = "maps.city-of-example.gov.au"
    alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000010"
  }

  assert {
    condition     = one([for e in local.primary_container_environment : e.value if e.name == "Public__BaseUrl"]) == "https://maps.city-of-example.gov.au"
    error_message = "A custom domain on any TLD with an HTTPS ALB must set Public__BaseUrl=https://<domain_name>."
  }

  assert {
    condition     = output.service_url == "https://maps.city-of-example.gov.au" && output.public_base_url == output.service_url
    error_message = "service_url and the rendered Public__BaseUrl must agree on the customer domain."
  }
}

run "managed_certificate_domain_sets_public_base_url_on_canary_too" {
  command = plan

  variables {
    domain_name                               = "gis.example.org"
    route53_zone_id                           = "Z0123456789ABCDEFGHIJ"
    canary_enabled                            = true
    redis_auth_token                          = "aA1aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    deployment_mode                           = "MultiNode"
    file_storage_provider                     = "AwsS3"
    file_storage_aws_s3_bucket_name           = "honua-test-files"
    redis_enabled                             = true
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }

  override_resource {
    target          = aws_acm_certificate.this[0]
    override_during = plan
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000011"
      domain_validation_options = [{
        domain_name           = "gis.example.org"
        resource_record_name  = "_0123456789abcdef.gis.example.org."
        resource_record_type  = "CNAME"
        resource_record_value = "_fedcba9876543210.acm-validations.aws."
      }]
    }
  }

  assert {
    condition = alltrue([
      for environment in [local.primary_container_environment, local.canary_container_environment] :
      one([for e in environment : e.value if e.name == "Public__BaseUrl"]) == "https://gis.example.org"
    ])
    error_message = "Stable and canary tasks must both carry Public__BaseUrl for the managed custom domain."
  }
}

run "plain_http_domain_sets_no_public_base_url" {
  command = plan

  variables {
    domain_name = "gis.example.org"
  }

  assert {
    condition     = !contains([for e in local.primary_container_environment : e.name], "Public__BaseUrl")
    error_message = "domain_name without an HTTPS listener is not served on that name, so no Public__BaseUrl is set."
  }
}

run "explicit_public_base_url_wins_and_trailing_slash_is_trimmed" {
  command = plan

  variables {
    domain_name         = "origin.example.net"
    alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000010"
    public_base_url     = "https://maps.example.com/gis/"
  }

  assert {
    condition     = one([for e in local.primary_container_environment : e.value if e.name == "Public__BaseUrl"]) == "https://maps.example.com/gis"
    error_message = "An explicit public_base_url (for example a CDN on the customer's domain) must win over domain_name."
  }
}

run "public_base_url_without_a_domain" {
  command = plan

  variables {
    public_base_url = "http://gis.internal.example:8080"
  }

  assert {
    condition     = one([for e in local.primary_container_environment : e.value if e.name == "Public__BaseUrl"]) == "http://gis.internal.example:8080"
    error_message = "public_base_url must be rendered even without domain_name (ports and plain http are accepted by the server)."
  }
}

run "operator_additional_env_value_is_kept" {
  command = plan

  variables {
    domain_name         = "gis.example.org"
    alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000010"
    additional_env      = { PUBLIC_BASE_URL = "https://front.example.org" }
  }

  assert {
    condition = (
      !contains([for e in local.primary_container_environment : e.name], "Public__BaseUrl") &&
      one([for e in local.primary_container_environment : e.value if e.name == "PUBLIC_BASE_URL"]) == "https://front.example.org"
    )
    error_message = "A PUBLIC_BASE_URL / Public__BaseUrl in additional_env must not be shadowed (the server reads Public:BaseUrl first)."
  }
}

run "public_base_url_and_additional_env_conflict_warns" {
  command = plan

  variables {
    public_base_url = "https://maps.example.com"
    additional_env  = { "Public:BaseUrl" = "https://front.example.org" }
  }

  expect_failures = [check.public_base_url_single_source]
}

run "bare_host_public_base_url_is_rejected" {
  command = plan

  variables {
    public_base_url = "gis.example.com"
  }

  expect_failures = [var.public_base_url]
}
