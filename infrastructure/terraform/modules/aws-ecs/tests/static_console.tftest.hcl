# Static Console origin isolation and private-network PostGIS bootstrap.
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

  redis_enabled           = false
  kms_key_arn             = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
  alb_access_logs_enabled = false
}

run "static_console_private_origins" {
  command = plan
  variables {
    redis_enabled                             = true
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:key-ring-AbC123"
    domain_name                               = "maps.example.com"
    alb_certificate_arn                       = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    alb_enable_http_redirect                  = false
    enable_postgis                            = false
    static_console = {
      viewer_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      bundle_version         = "rc.2"
    }
    postgis_bootstrap_image           = "docker.io/library/postgres@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    file_storage_provider             = "AwsS3"
    file_storage_aws_s3_create_bucket = true
  }
  assert {
    condition     = aws_cloudfront_distribution.console[0].default_cache_behavior[0].target_origin_id == "api" && aws_cloudfront_distribution.console[0].default_cache_behavior[0].cache_policy_id == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    error_message = "API requests must go to ALB without CloudFront response caching."
  }
  assert {
    condition     = toset([for behavior in aws_cloudfront_distribution.console[0].ordered_cache_behavior : behavior.path_pattern]) == toset(["/console", "/console/*"])
    error_message = "Only Console paths may select the private S3 origin."
  }
  assert {
    condition     = aws_lb_listener.https[0].default_action[0].type == "fixed-response" && length(aws_lb_listener_rule.cloudfront) == 1 && length(aws_security_group.alb.ingress) == 1
    error_message = "Direct ALB requests must be denied; only CloudFront may reach the API listener."
  }
  assert {
    condition     = length(aws_s3_bucket.deployment) == 2 && alltrue([for block in aws_s3_bucket_public_access_block.deployment : block.block_public_acls && block.block_public_policy && block.ignore_public_acls && block.restrict_public_buckets])
    error_message = "Console and shared data buckets must remain private."
  }
  assert {
    condition     = local.postgis_bootstrap_dependencies[0].containerName == "postgis" && local.postgis_bootstrap_dependencies[0].condition == "SUCCESS" && local.postgis_bootstrap_containers[0].entryPoint[0] == "psql" && local.postgis_bootstrap_containers[0].essential == false
    error_message = "Honua must wait for successful private-network PostGIS initialization."
  }
  assert {
    condition     = aws_elasticache_replication_group.redis[0].at_rest_encryption_enabled && aws_elasticache_replication_group.redis[0].transit_encryption_enabled && aws_elasticache_replication_group.redis[0].node_type == "cache.t4g.micro" && length(aws_secretsmanager_secret.redis_connection) == 1 && length(aws_security_group.redis[0].ingress) == 1 && length(aws_security_group.redis[0].egress) == 0
    error_message = "Managed Redis must use encrypted private ECS-only access and a connection secret."
  }
  assert {
    condition     = !var.db_publicly_accessible && length(module.rds) == 1 && length(null_resource.enable_postgis) == 0
    error_message = "RDS must remain encrypted and private without runner-based psql."
  }
}

run "reject_static_console_without_tls" {
  command = plan
  variables {
    static_console = {
      viewer_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      bundle_version         = "rc.2"
    }
  }
  expect_failures = [terraform_data.static_console_validation]
}
