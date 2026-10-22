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
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/honua-test/0000000000000000"
      arn_suffix = "app/honua-test/0000000000000000"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/honua-test/0000000000000000"
      arn_suffix = "targetgroup/honua-test/0000000000000000"
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
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"

  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
  image                                     = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  canary_image                              = "ghcr.io/honua-io/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  admin_password                            = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  connection_encryption_master_key          = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

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
}

run "default_renders_no_control_plane_or_migration_safety" {
  command = apply

  assert {
    condition = (
      output.deploy_control_plane == null &&
      length(aws_iam_role_policy.deploy_control_plane) == 0 &&
      length(aws_lb_listener_rule.protected_rollout) == 0 &&
      output.migration_safety_environment == {} &&
      length([for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : entry if startswith(entry.name, "ControlPlane__DeployTargets__") || startswith(entry.name, "ControlPlane__TelemetryConnections__") || startswith(entry.name, "Database__MigrationSafety__")]) == 0
    )
    error_message = "Without deploy_control_plane or migration_safety the module must render no deploy target, telemetry connection, migration-safety key, rule or policy."
  }
}

run "in_service_control_plane_renders_target_connection_and_scoped_policy" {
  command = apply

  variables {
    deploy_control_plane = {
      canary_weight_percentage = 10
    }
  }

  assert {
    condition = alltrue([
      for slot in [aws_ecs_task_definition.this.container_definitions, aws_ecs_task_definition.canary[0].container_definitions] :
      alltrue([
        contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "ControlPlane__DeployTargets__0__Backend=honua-aws-ecs-alb"),
        contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "ControlPlane__DeployTargets__0__TargetKind=AwsEcs"),
        contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "ControlPlane__DeployTargets__0__TargetName=honua-dev-canary-service"),
        contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "ControlPlane__DeployTargets__0__RequiresApproval=true"),
        contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "ControlPlane__TelemetryConnections__0__ConnectionId=aws-cloudwatch"),
        contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "ControlPlane__TelemetryConnections__0__Provider=cloudwatch"),
        contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "ControlPlane__TelemetryConnections__0__BaseUrl=https://monitoring.us-east-1.amazonaws.com"),
        contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "ControlPlane__TelemetryConnections__0__Region=us-east-1"),
      ])
    ])
    error_message = "Both serving slots must register the honua-aws-ecs-alb target and the CloudWatch telemetry connection, because every MultiNode task reconciles deploy operations."
  }

  assert {
    condition = (
      output.deploy_control_plane.status == "configured-unverified" &&
      output.deploy_control_plane.controller_topology == "in-service-stable-and-canary" &&
      output.deploy_control_plane.parameters["aws.ecs.cluster"] == aws_ecs_cluster.this.arn &&
      output.deploy_control_plane.parameters["aws.ecs.canary_service"] == aws_ecs_service.canary[0].name &&
      output.deploy_control_plane.parameters["aws.ecs.stable_service"] == aws_ecs_service.this.name &&
      output.deploy_control_plane.parameters["aws.alb.listener_rule_arn"] == aws_lb_listener_rule.protected_rollout[0].arn &&
      output.deploy_control_plane.parameters["aws.alb.stable_target_group_arn"] == aws_lb_target_group.this.arn &&
      output.deploy_control_plane.parameters["aws.alb.canary_target_group_arn"] == aws_lb_target_group.canary[0].arn &&
      output.deploy_control_plane.parameters["aws.ecs.canary_weight_percentage"] == "10" &&
      output.deploy_control_plane.parameters["telemetry.connection"] == "aws-cloudwatch" &&
      output.deploy_control_plane.parameters["telemetry.sample_count.minimum"] == "50" &&
      output.deploy_control_plane.parameters["telemetry.latency_p95.threshold_ms"] == "1500" &&
      strcontains(output.deploy_control_plane.parameters["telemetry.sample_count.query"], "TargetGroup=\"targetgroup/honua-test/0000000000000000\"") &&
      strcontains(output.deploy_control_plane.parameters["telemetry.latency_p95.query"], "LoadBalancer=\"app/honua-test/0000000000000000\"") &&
      !contains(keys(output.deploy_control_plane.parameters), "telemetry.max_staleness_seconds") &&
      !contains(keys(output.deploy_control_plane.parameters), "telemetry.error_rate.query") &&
      output.deploy_control_plane.error_rate_signal == false
    )
    error_message = "The target parameters must name the installed cluster, services, rule and target groups, scope CloudWatch queries to the canary target group, and omit keys the CloudWatch provider rejects."
  }

  assert {
    condition = (
      length([for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : entry if can(regex("^ControlPlane__DeployTargets__0__ParameterEntries__[0-9]+__Key$", entry.name))]) == length(output.deploy_control_plane.parameters) &&
      contains([for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : entry.value if can(regex("^ControlPlane__DeployTargets__0__ParameterEntries__[0-9]+__Key$", entry.name))], "aws.alb.listener_rule_arn")
    )
    error_message = "Dotted parameter keys must travel as ParameterEntries key/value pairs, one per parameter."
  }

  assert {
    condition = (
      aws_lb_listener_rule.protected_rollout[0].priority == 50000 &&
      length([for tg in aws_lb_listener_rule.protected_rollout[0].action[0].forward[0].target_group : tg if tg.arn == aws_lb_target_group.this.arn && tg.weight == 100]) == 1 &&
      length([for tg in aws_lb_listener_rule.protected_rollout[0].action[0].forward[0].target_group : tg if tg.arn == aws_lb_target_group.canary[0].arn && tg.weight == 0]) == 1
    )
    error_message = "The in-service controller must own the same stable=100/candidate=0 weighted rule as the external topology."
  }

  assert {
    condition = (
      aws_iam_role_policy.deploy_control_plane[0].role == aws_iam_role.task.id &&
      jsondecode(aws_iam_role_policy.deploy_control_plane[0].policy).Statement[0].Resource == [aws_ecs_service.canary[0].id] &&
      jsondecode(aws_iam_role_policy.deploy_control_plane[0].policy).Statement[0].Action == ["ecs:DescribeServices", "ecs:UpdateService"] &&
      jsondecode(aws_iam_role_policy.deploy_control_plane[0].policy).Statement[1].Action == ["ecs:DescribeServices"] &&
      jsondecode(aws_iam_role_policy.deploy_control_plane[0].policy).Statement[2].Resource == [aws_lb_listener_rule.protected_rollout[0].arn] &&
      contains(jsondecode(aws_iam_role_policy.deploy_control_plane[0].policy).Statement[3].Action, "cloudwatch:GetMetricData") &&
      length(aws_iam_role_policy.recovery_controller) == 0
    )
    error_message = "Task-role mutation must be scoped to the canary service and the weighted rule; the stable service is describe-only."
  }
}

run "operator_error_rate_query_and_probe_are_rendered" {
  command = apply

  variables {
    deploy_control_plane = {
      target_id            = "prod-ecs"
      requires_approval    = false
      error_rate_query     = "SUM(SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} MetricName=\"HTTPCode_Target_5XX_Count\"', 'Sum', 300))"
      error_rate_threshold = 0.02
      healthz_url          = "https://candidate.example.com/healthz/ready"
    }
  }

  assert {
    condition = (
      output.deploy_control_plane.target_id == "prod-ecs" &&
      output.deploy_control_plane.error_rate_signal &&
      output.deploy_control_plane.parameters["telemetry.error_rate.threshold"] == "0.02" &&
      output.deploy_control_plane.parameters["telemetry.healthz.url"] == "https://candidate.example.com/healthz/ready" &&
      !contains(keys(output.deploy_control_plane.parameters), "aws.ecs.canary_weight_percentage") &&
      contains([for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : "${entry.name}=${entry.value}"], "ControlPlane__DeployTargets__0__RequiresApproval=false")
    )
    error_message = "Operator-supplied error-rate query, threshold, probe and approval posture must reach the target; a null canary weight means a direct cutover."
  }
}

run "control_plane_and_external_safety_are_mutually_exclusive" {
  command = plan

  variables {
    deploy_control_plane = {}
    deployment_safety = {
      controller_role_name       = "retained-controller"
      telemetry_connection_id    = "cert-prometheus"
      prometheus_canary_job      = "cert-cell-canary"
      functional_probe_url       = "https://candidate.example.com/fixture"
      functional_expected_sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    }
  }

  expect_failures = [terraform_data.deploy_control_plane_validation]
}

run "control_plane_requires_canary" {
  command = plan

  variables {
    canary_enabled       = false
    desired_count        = 1
    max_capacity         = 1
    deploy_control_plane = {}
  }

  expect_failures = [terraform_data.deploy_control_plane_validation]
}

run "control_plane_refuses_raw_catalog_overrides" {
  command = plan

  variables {
    deploy_control_plane = {}
    canary_additional_env = {
      "ControlPlane:TelemetryConnections:0:BaseUrl" = "https://attacker.example.com"
    }
  }

  expect_failures = [terraform_data.deploy_control_plane_validation]
}

run "fractional_canary_weight_is_rejected" {
  command = plan

  variables {
    deploy_control_plane = {
      canary_weight_percentage = 12.5
    }
  }

  expect_failures = [var.deploy_control_plane]
}

run "migration_safety_renders_on_both_slots" {
  command = apply

  variables {
    migration_safety = {
      contract_apply_policy = "Gate"
      backup_command        = "/opt/honua/backup.sh"
      enforce               = true
    }
    additional_env = {
      Database__MigrationSafety__ContractApplyPolicy = "Auto"
    }
  }

  assert {
    condition = alltrue([
      for slot in [aws_ecs_task_definition.this.container_definitions, aws_ecs_task_definition.canary[0].container_definitions] :
      contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "Database__MigrationSafety__ContractApplyPolicy=Gate") &&
      contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "Database__MigrationSafety__BackupCommand=/opt/honua/backup.sh") &&
      contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "Database__MigrationSafety__Enforce=true") &&
      !contains([for entry in jsondecode(slot)[0].environment : "${entry.name}=${entry.value}"], "Database__MigrationSafety__ContractApplyPolicy=Auto")
    ])
    error_message = "Typed migration safety must reach the stable and canary task definitions and win over additional_env."
  }
}

run "invalid_contract_apply_policy_is_rejected" {
  command = plan

  variables {
    migration_safety = {
      contract_apply_policy = "Always"
    }
  }

  expect_failures = [var.migration_safety]
}
