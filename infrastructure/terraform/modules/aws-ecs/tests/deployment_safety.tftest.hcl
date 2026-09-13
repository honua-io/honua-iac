mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      name = "retained-controller"
      arn  = "arn:aws:iam::123456789012:role/retained-controller"
    }
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

mock_provider "random" {}
mock_provider "null" {}

variables {
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

run "native_safety_wires_bounded_runtime_and_retained_actuator" {
  command = apply

  assert {
    condition = (
      output.deployment_safety.status == "configured-unverified" &&
      output.deployment_safety.backend_name == "honua-aws-ecs-alb" &&
      output.deployment_safety.controller_role_arn == "arn:aws:iam::123456789012:role/retained-controller" &&
      output.deployment_safety.parameters["deployment.protection.observation_window_seconds"] == "600" &&
      output.deployment_safety.parameters["deployment.rollback.observation_timeout_seconds"] == "300" &&
      output.deployment_safety.parameters["telemetry.warmup_seconds"] == "180" &&
      output.deployment_safety.parameters["telemetry.evidence_grace_seconds"] == "120" &&
      output.deployment_safety.parameters["telemetry.exposure_deadline_seconds"] == "900" &&
      output.deployment_safety.parameters["telemetry.max_staleness_seconds"] == "60" &&
      output.deployment_safety.parameters["telemetry.prometheus.canary_job"] == "cert-cell-canary" &&
      output.deployment_safety.parameters["telemetry.golden_query.expected_sha256"] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    error_message = "The handoff must carry the bounded canonical runtime parameters and independent functional expectation without claiming certification."
  }
  assert {
    condition = (
      aws_lb_listener_rule.protected_rollout[0].priority == 50000 &&
      length(aws_lb_listener_rule.protected_rollout[0].action[0].forward[0].target_group) == 2 &&
      sum([for tg in aws_lb_listener_rule.protected_rollout[0].action[0].forward[0].target_group : tg.weight]) == 100 &&
      output.deployment_safety.parameters["aws.alb.listener_rule_arn"] == aws_lb_listener_rule.protected_rollout[0].arn &&
      output.deployment_safety.parameters["aws.ecs.canary_service"] == aws_ecs_service.canary[0].name &&
      aws_ecs_task_definition.this.skip_destroy && aws_ecs_task_definition.canary[0].skip_destroy
    )
    error_message = "The backend must control the installed two-target traffic rule and retain both task definitions."
  }
  assert {
    condition = (
      aws_iam_role_policy.recovery_controller[0].role == "retained-controller" &&
      jsondecode(aws_iam_role_policy.recovery_controller[0].policy).Statement[0].Resource == [aws_ecs_service.canary[0].id] &&
      jsondecode(aws_iam_role_policy.recovery_controller[0].policy).Statement[1].Resource == [aws_lb_listener_rule.protected_rollout[0].arn] &&
      jsondecode(aws_iam_role_policy.recovery_controller[0].policy).Statement[1].Action == ["elasticloadbalancing:ModifyRule"] &&
      aws_iam_role_policy.file_storage_s3[0].role == aws_iam_role.task.id &&
      jsondecode(aws_iam_role_policy.file_storage_s3[0].policy).Statement[1].Resource == ["arn:aws:s3:::honua-test-files/*"] &&
      aws_iam_role_policy_attachment.task_secrets.role == aws_iam_role.task_execution.name &&
      output.cache_configured
    )
    error_message = "Mutation must be scoped to the canary/rule on a retained role; workload storage and execution secret permissions must remain separate."
  }
}

run "invalid_observation_bound_is_rejected" {
  command = plan
  variables {
    deployment_safety = {
      controller_role_name       = "retained-controller"
      telemetry_connection_id    = "cert-prometheus"
      prometheus_canary_job      = "cert-cell-canary"
      functional_probe_url       = "https://candidate.example.com/fixture"
      functional_expected_sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      observation_window_seconds = 86401
    }
  }
  expect_failures = [var.deployment_safety]
}
run "invalid_recovery_bound_is_rejected" {
  command = plan
  variables {
    deployment_safety = {
      controller_role_name       = "retained-controller"
      telemetry_connection_id    = "cert-prometheus"
      prometheus_canary_job      = "cert-cell-canary"
      functional_probe_url       = "https://candidate.example.com/fixture"
      functional_expected_sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
      recovery_timeout_seconds   = 0
    }
  }
  expect_failures = [var.deployment_safety]
}
run "missing_metric_source_is_rejected" {
  command = plan
  variables {
    deployment_safety = {
      controller_role_name       = "retained-controller"
      telemetry_connection_id    = ""
      prometheus_canary_job      = "cert-cell-canary"
      functional_probe_url       = "https://candidate.example.com/fixture"
      functional_expected_sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    }
  }
  expect_failures = [var.deployment_safety]
}
run "missing_functional_expectation_is_rejected" {
  command = plan
  variables {
    deployment_safety = {
      controller_role_name       = "retained-controller"
      telemetry_connection_id    = "cert-prometheus"
      prometheus_canary_job      = "cert-cell-canary"
      functional_probe_url       = "https://candidate.example.com/fixture"
      functional_expected_sha256 = ""
    }
  }
  expect_failures = [var.deployment_safety]
}
run "mutable_prior_image_is_rejected" {
  command = plan
  variables { image = "ghcr.io/honua-io/honua-server:latest" }
  expect_failures = [aws_lb_listener_rule.protected_rollout]
}
run "candidate_role_cannot_own_recovery" {
  command = plan
  variables {
    deployment_safety = {
      controller_role_name       = "honua-dev-ecs-task"
      telemetry_connection_id    = "cert-prometheus"
      prometheus_canary_job      = "cert-cell-canary"
      functional_probe_url       = "https://candidate.example.com/fixture"
      functional_expected_sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    }
  }
  expect_failures = [aws_iam_role_policy.recovery_controller]
}
run "cold_canary_is_rejected" {
  command = plan
  variables { canary_desired_count = 0 }
  expect_failures = [aws_security_group.alb]
}

run "single_service_cannot_enable_native_canary_backend" {
  command = plan
  variables { canary_enabled = false }
  expect_failures = [aws_security_group.alb]
}
