# HSTS / forwarded-headers contract behind the TLS-terminating ALB.
#
# honua-release e2e-cloud-aws run 38047168879: the first ECS cells served over
# HTTPS (domain_name + route53_zone_id) returned every baseline security header
# except Strict-Transport-Security, because the ALB forwards plain HTTP to the
# task and honua-server suppresses HSTS on http requests by default
# (SecurityHeaders:HstsHttpsOnly, SecurityHeadersMiddleware.cs).
#
# With any ALB certificate (operator ACM ARN or the module-managed certificate)
# both task definitions must carry SecurityHeaders__HstsHttpsOnly=false and
# ASPNETCORE_FORWARDEDHEADERS_ENABLED=true. A plain-HTTP ALB must carry neither.
# Canary runs use the MultiNode + Redis + AwsS3 topology the canary slot requires.

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

run "operator_certificate_emits_hsts_and_trusts_alb_forwarding" {
  command = plan
  variables {
    alb_certificate_arn                       = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000010"
    canary_enabled                            = true
    redis_auth_token                          = "aA1aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    deployment_mode                           = "MultiNode"
    file_storage_provider                     = "AwsS3"
    file_storage_aws_s3_bucket_name           = "honua-test-files"
    redis_enabled                             = true
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }
  assert {
    condition = alltrue([
      for environment in [local.primary_container_environment, local.canary_container_environment] :
      one([for e in environment : e.value if e.name == "SecurityHeaders__HstsHttpsOnly"]) == "false" &&
      one([for e in environment : e.value if e.name == "ASPNETCORE_FORWARDEDHEADERS_ENABLED"]) == "true"
    ])
    error_message = "With alb_certificate_arn set, stable and canary tasks must emit HSTS and trust the ALB's X-Forwarded-Proto/For."
  }
}

run "managed_certificate_emits_hsts_and_trusts_alb_forwarding" {
  command = plan
  variables {
    domain_name     = "honua.example.com"
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
  }
  # The validation records are keyed by the certificate's computed
  # domain_validation_options, so pin them at plan time.
  override_resource {
    target          = aws_acm_certificate.this[0]
    override_during = plan
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000011"
      domain_validation_options = [{
        domain_name           = "honua.example.com"
        resource_record_name  = "_0123456789abcdef.honua.example.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_fedcba9876543210.acm-validations.aws."
      }]
    }
  }
  assert {
    condition = (
      one([for e in local.primary_container_environment : e.value if e.name == "SecurityHeaders__HstsHttpsOnly"]) == "false" &&
      one([for e in local.primary_container_environment : e.value if e.name == "ASPNETCORE_FORWARDEDHEADERS_ENABLED"]) == "true"
    )
    error_message = "With the module-managed certificate (domain_name + route53_zone_id), the task must emit HSTS and trust the ALB's X-Forwarded-Proto/For."
  }
}

run "additional_env_cannot_reenable_https_only_hsts" {
  command = plan
  variables {
    alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000010"
    additional_env      = { SecurityHeaders__HstsHttpsOnly = "true" }
  }
  assert {
    condition     = one([for e in local.primary_container_environment : e.value if e.name == "SecurityHeaders__HstsHttpsOnly"]) == "false"
    error_message = "The HTTPS-ALB contract must win over additional_env, like the other module-owned runtime settings."
  }
}

run "plain_http_alb_keeps_default_behaviour" {
  command = plan
  variables {
    canary_enabled                            = true
    redis_auth_token                          = "aA1aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    deployment_mode                           = "MultiNode"
    file_storage_provider                     = "AwsS3"
    file_storage_aws_s3_bucket_name           = "honua-test-files"
    redis_enabled                             = true
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  }
  assert {
    condition = alltrue([
      for environment in [local.primary_container_environment, local.canary_container_environment] :
      !contains([for e in environment : e.name], "SecurityHeaders__HstsHttpsOnly") &&
      !contains([for e in environment : e.name], "ASPNETCORE_FORWARDEDHEADERS_ENABLED")
    ])
    error_message = "A plain-HTTP ALB must not change HSTS or forwarded-header behaviour."
  }
}
