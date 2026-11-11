# alb_enable_http_redirect passthrough from the ECS root.
#
# The release harness sets it for HTTPS cells, so the root must pass it to
# modules/aws-ecs with the module's default (true). Plan-only with mocked
# providers; no credentials, no AWS calls.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "random" {}
mock_provider "null" {}

variables {
  # A reachable cell: without an ingress list or certificate the root's
  # alb_reachable_from_outside_vpc check fails, which terraform test reports
  # as a failed run. 203.0.113.0/24 is TEST-NET-3 (RFC 5737).
  allow_http_ingress_cidrs = ["203.0.113.10/32"]

  operation_key_ring_certificate_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"
  operation_key_ring_certificate_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  audit_chain_key_secret_arn                        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
  honua_image                                       = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_admin_password                              = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_connection_encryption_master_key            = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  existing_vpc_id             = "vpc-0123456789abcdef0"
  existing_vpc_cidr           = "10.0.0.0/16"
  existing_public_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
  existing_private_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]

  existing_db_endpoint          = "postgres.example.internal"
  existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"

  redis_enabled           = false
  alb_access_logs_enabled = false

  deployment_mode                 = "MultiNode"
  desired_count                   = 2
  max_capacity                    = 2
  redis_connection_string         = "redis.example.internal:6379,password=test,ssl=true"
  redis_connection_cidrs          = ["10.0.0.0/16"]
  file_storage_provider           = "AwsS3"
  file_storage_aws_s3_bucket_name = "honua-test-files"
  canary_enabled                  = true
  canary_desired_count            = 1
  deployment_safety = {
    controller_role_name    = "retained-controller"
    telemetry_connection_id = "cert-prometheus"
    prometheus_canary_job   = "cert-cell-canary"
    functional_probe_url    = "https://candidate.example.com/fixture"
    # SHA-256 of the independently specified golden response bytes: abc
    functional_expected_sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  }
}


run "redirect_defaults_on_for_https" {
  command = plan

  variables {
    alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000010"
  }

  assert {
    condition     = var.alb_enable_http_redirect == true && module.honua.alb_http_redirect_enabled == true
    error_message = "alb_enable_http_redirect must default to the module default (true) and give an HTTPS ALB its redirect listener."
  }
}

run "redirect_off_passes_through" {
  command = plan

  variables {
    alb_certificate_arn      = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000010"
    alb_enable_http_redirect = false
  }

  assert {
    condition     = module.honua.alb_http_redirect_enabled == false
    error_message = "alb_enable_http_redirect = false must reach the module and remove the redirect listener."
  }
}
