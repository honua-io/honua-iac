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

  mock_resource "aws_cloudfront_function" {
    defaults = {
      arn = "arn:aws:cloudfront::123456789012:function/honua-console"
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


run "actual_managed_admin_secret_version" {
  command = apply
  assert {
    condition     = output.admin_password_secret_version_id == aws_secretsmanager_secret_version.admin_password.version_id && output.admin_password_secret_version_id != var.admin_password
    error_message = "Bootstrap readback must expose the actual immutable managed version ID, never password content."
  }
  assert {
    condition     = alltrue([for container in jsondecode(aws_ecs_task_definition.this.container_definitions) : !can(container.dependsOn) && !can(container.startTimeout)])
    error_message = "Existing stacks must keep task definitions unchanged when PostGIS bootstrap is absent."
  }
  assert {
    condition     = length([for secret in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets : secret if secret.name == "HONUA_ADMIN_PASSWORD" && secret.valueFrom == output.admin_password_secret_arn]) == 1
    error_message = "Existing Server credential injection must retain its original base ARN behavior."
  }
}

run "static_console_private_origins" {
  command = apply
  override_resource {
    target          = aws_acm_certificate.this[0]
    override_during = plan
    values = {
      arn                 = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
      id                  = "test-certificate"
      region              = "us-east-1"
      renewal_eligibility = "ELIGIBLE"
      not_after           = "2027-12-31T00:00:00Z"
      not_before          = "2026-01-01T00:00:00Z"
      type                = "AMAZON_ISSUED"
      key_algorithm       = "RSA_2048"
      status              = "ISSUED"
      domain_validation_options = [{
        domain_name           = "maps.example.com"
        resource_record_name  = "_test.maps.example.com"
        resource_record_type  = "CNAME"
        resource_record_value = "_test.acm-validations.aws."
      }]
    }
  }
  variables {
    existing_db_endpoint                      = ""
    existing_db_connection_string             = ""
    migration_task                            = true
    redis_enabled                             = true
    redis_node_type                           = "cache.t4g.micro"
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:key-ring-AbC123"
    domain_name                               = "maps.example.com"
    route53_zone_id                           = "Z00000000000000000000"
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
    condition     = aws_route53_record.service_alias[0].alias[0].name == aws_cloudfront_distribution.console[0].domain_name && aws_route53_record.service_alias[0].alias[0].zone_id == aws_cloudfront_distribution.console[0].hosted_zone_id
    error_message = "The stable service alias must target CloudFront when static Console is enabled."
  }
  assert {
    condition = alltrue([for origin in aws_cloudfront_distribution.console[0].origin :
      one(origin.custom_header).value == one(one(one(aws_lb_listener_rule.cloudfront[0].condition).http_header).values)
      if origin.origin_id == "api"
    ])
    error_message = "CloudFront must send the same private origin header required by the ALB listener."
  }
  assert {
    condition = alltrue([for statement in data.aws_iam_policy_document.deployment_bucket["console"].statement :
      one(statement.condition).variable == "AWS:SourceArn" && one(one(statement.condition).values) == aws_cloudfront_distribution.console[0].arn
      if statement.sid == "CloudFrontReadOnly"
    ]) && aws_cloudfront_origin_access_control.console[0].signing_behavior == "always"
    error_message = "Console OAC reads must be signed and restricted to this exact distribution."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.file_storage_s3[0].policy).Statement[1].Resource[0] == "arn:aws:s3:::${aws_s3_bucket.deployment["files"].id}/*"
    error_message = "Runtime object access must target the generated shared bucket."
  }
  assert {
    condition = alltrue([for container in jsondecode(aws_ecs_task_definition.migrate[0].container_definitions) :
      container.dependsOn[0].containerName == "postgis" && container.dependsOn[0].condition == "SUCCESS"
      if container.name != "postgis"
    ]) && length(jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)) == 2
    error_message = "One-shot migrations must wait for the same private PostGIS bootstrap as the service."
  }
  assert {
    condition     = aws_lb.this.xff_header_processing_mode == "preserve" && alltrue([for origin in aws_cloudfront_distribution.console[0].origin : origin.custom_origin_config[0].origin_read_timeout == 60 && origin.custom_origin_config[0].origin_keepalive_timeout < 60 if origin.origin_id == "api"])
    error_message = "The edge topology must preserve CloudFront's rightmost viewer IP and the ALB's 60-second API response window."
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
