# migration_task: one-shot migrate-only ECS task, HONUA_SKIP_MIGRATIONS on serving
# tasks, and the exact run-task/wait/exit-code/summary commands.

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

  mock_resource "aws_ecs_cluster" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:123456789012:cluster/honua-dev-cluster"
    }
  }

  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/honua-dev-migrate-task:7"
    }
  }

  mock_resource "aws_security_group" {
    defaults = {
      id = "sg-0123456789abcdef0"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

variables {
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

run "default_keeps_inline_migrations" {
  command = apply

  assert {
    condition     = output.migration_task == null && length(aws_ecs_task_definition.migrate) == 0
    error_message = "Without migration_task the module must register no migration task definition and report no run command."
  }

  assert {
    condition = length([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      entry if contains(["HONUA_SKIP_MIGRATIONS", "HONUA_MIGRATE_ONLY"], entry.name)
    ]) == 0
    error_message = "The default serving task must keep migrating inline: no HONUA_SKIP_MIGRATIONS or HONUA_MIGRATE_ONLY."
  }
}

run "migration_task_renders_migrator_and_skips_on_serving" {
  command = apply

  variables {
    migration_task   = true
    migration_safety = { contract_apply_policy = "Gate", backup_command = "/opt/honua/pre-migrate.sh" }
    additional_env   = { Public__BaseUrl = "https://honua.example.com" }
  }

  # Serving task: verify the journal, never migrate.
  assert {
    condition = length([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      entry if entry.name == "HONUA_SKIP_MIGRATIONS" && entry.value == "true"
    ]) == 1
    error_message = "With migration_task the serving task must carry exactly one HONUA_SKIP_MIGRATIONS=true."
  }

  assert {
    condition = length([
      for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment :
      entry if entry.name == "HONUA_MIGRATE_ONLY"
    ]) == 0
    error_message = "The serving task must never carry HONUA_MIGRATE_ONLY."
  }

  # Migrator: same image, secrets, roles and environment, plus HONUA_MIGRATE_ONLY.
  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0].image == var.image &&
      jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0].secrets == jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets &&
      aws_ecs_task_definition.migrate[0].task_role_arn == aws_ecs_task_definition.this.task_role_arn &&
      aws_ecs_task_definition.migrate[0].execution_role_arn == aws_ecs_task_definition.this.execution_role_arn &&
      aws_ecs_task_definition.migrate[0].requires_compatibilities == toset(["FARGATE"]) &&
      aws_ecs_task_definition.migrate[0].family == "honua-dev-migrate-task"
    )
    error_message = "The migration task must run the serving image with the serving secrets, roles and Fargate compatibility."
  }

  assert {
    condition = {
      for entry in jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0].environment : entry.name => entry.value
      } == merge(
      { for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : entry.name => entry.value if entry.name != "HONUA_SKIP_MIGRATIONS" },
      { HONUA_MIGRATE_ONLY = "true" }
    )
    error_message = "The migrator environment must equal the serving environment minus HONUA_SKIP_MIGRATIONS plus HONUA_MIGRATE_ONLY=true (so MigrationSafety and all settings match)."
  }

  assert {
    condition = (
      contains([for entry in jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0].environment : "${entry.name}=${entry.value}"], "Database__MigrationSafety__ContractApplyPolicy=Gate") &&
      contains([for entry in jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0].environment : "${entry.name}=${entry.value}"], "Database__MigrationSafety__BackupCommand=/opt/honua/pre-migrate.sh")
    )
    error_message = "The migrator must carry the migration_safety gates."
  }

  assert {
    condition = (
      lookup(jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0], "portMappings", []) == [] &&
      lookup(jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0], "healthCheck", null) == null &&
      jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0].logConfiguration.options["awslogs-stream-prefix"] == "honua-migrate"
    )
    error_message = "The migrator listens on nothing, has no health check, and logs under the honua-migrate stream prefix."
  }

  # The exact operator commands.
  assert {
    condition = (
      output.migration_task.launch_type == "FARGATE" &&
      output.migration_task.cluster_arn == aws_ecs_cluster.this.arn &&
      output.migration_task.task_definition_arn == aws_ecs_task_definition.migrate[0].arn &&
      output.migration_task.subnets == var.existing_private_subnet_ids &&
      output.migration_task.security_groups == [aws_security_group.ecs.id] &&
      output.migration_task.assign_public_ip == "DISABLED" &&
      output.migration_task.run_task_command == "aws ecs run-task --region us-east-1 --cluster ${aws_ecs_cluster.this.arn} --task-definition ${aws_ecs_task_definition.migrate[0].arn} --launch-type FARGATE --count 1 --started-by honua-migrate --network-configuration 'awsvpcConfiguration={subnets=[subnet-00000000000000003,subnet-00000000000000004],securityGroups=[${aws_security_group.ecs.id}],assignPublicIp=DISABLED}' --query 'tasks[0].taskArn' --output text" &&
      output.migration_task.wait_command == "aws ecs wait tasks-stopped --region us-east-1 --cluster ${aws_ecs_cluster.this.arn} --tasks \"$TASK_ARN\"" &&
      output.migration_task.exit_code_command == "aws ecs describe-tasks --region us-east-1 --cluster ${aws_ecs_cluster.this.arn} --tasks \"$TASK_ARN\" --query \"tasks[0].[containers[?name=='honua-migrate'].exitCode | [0], stoppedReason]\" --output text" &&
      output.migration_task.summary_command == "aws logs filter-log-events --region us-east-1 --log-group-name /honua/honua-dev --log-stream-names \"honua-migrate/honua-migrate/$${TASK_ARN##*/}\" --filter-pattern '\"honua.migrate-only/v1\"' --query 'events[].message' --output text"
    )
    error_message = "output.migration_task must give the exact run-task, wait, exit-code and summary commands for this cluster, task definition and network."
  }
}

run "migration_task_env_and_image_overrides" {
  command = apply

  variables {
    migration_task                = true
    migration_task_image          = "ghcr.io/honua-io/honua-server@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    migration_task_additional_env = { HONUA_APPROVE_CONTRACT_MIGRATIONS = "nonce-from-summary" }
    assign_public_ip              = true
    enable_nat_gateway            = false
  }

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0].image == var.migration_task_image &&
      jsondecode(aws_ecs_task_definition.this.container_definitions)[0].image == var.image
    )
    error_message = "migration_task_image must change only the migrator, so it can run before the serving image changes."
  }

  assert {
    condition = (
      contains([for entry in jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0].environment : "${entry.name}=${entry.value}"], "HONUA_APPROVE_CONTRACT_MIGRATIONS=nonce-from-summary") &&
      !contains([for entry in jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment : entry.name], "HONUA_APPROVE_CONTRACT_MIGRATIONS")
    )
    error_message = "migration_task_additional_env must reach only the migrator."
  }

  assert {
    condition     = output.migration_task.assign_public_ip == "ENABLED" && strcontains(output.migration_task.run_task_command, "assignPublicIp=ENABLED")
    error_message = "The run-task network configuration must follow assign_public_ip."
  }
}

run "migration_task_with_canary_migrates_for_the_candidate" {
  command = apply

  variables {
    migration_task                            = true
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    canary_image                              = "ghcr.io/honua-io/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    deployment_mode                           = "MultiNode"
    desired_count                             = 2
    max_capacity                              = 2
    redis_connection_string                   = "redis.example.internal:6379,password=test,ssl=true"
    redis_connection_cidrs                    = ["10.0.0.0/16"]
    file_storage_provider                     = "AwsS3"
    file_storage_aws_s3_bucket_name           = "honua-test-files"
    canary_enabled                            = true
    canary_desired_count                      = 1
    canary_additional_env                     = { Feature__Candidate = "on" }
  }

  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0].image == var.canary_image &&
      contains([for entry in jsondecode(aws_ecs_task_definition.migrate[0].container_definitions)[0].environment : "${entry.name}=${entry.value}"], "Feature__Candidate=on")
    )
    error_message = "With a canary, the migrator runs the candidate image with the canary environment."
  }

  assert {
    condition = alltrue([
      for definition in [aws_ecs_task_definition.this.container_definitions, aws_ecs_task_definition.canary[0].container_definitions] :
      length([for entry in jsondecode(definition)[0].environment : entry if entry.name == "HONUA_SKIP_MIGRATIONS" && entry.value == "true"]) == 1
    ])
    error_message = "Both the stable and canary serving tasks must skip migrations."
  }
}

run "reject_migrate_only_in_user_env" {
  command = plan
  variables {
    additional_env = { HONUA_MIGRATE_ONLY = "true" }
  }
  expect_failures = [terraform_data.migration_task_validation]
}

run "reject_migrate_only_in_migrator_env" {
  command = plan
  variables {
    migration_task                = true
    migration_task_additional_env = { honua_migrate_only = "false" }
  }
  expect_failures = [terraform_data.migration_task_validation]
}

run "reject_manual_skip_with_migration_task" {
  command = plan
  variables {
    migration_task = true
    additional_env = { HONUA_SKIP_MIGRATIONS = "false" }
  }
  expect_failures = [terraform_data.migration_task_validation]
}

run "reject_migrator_settings_without_migration_task" {
  command = plan
  variables {
    migration_task_image = "ghcr.io/honua-io/honua-server@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  }
  expect_failures = [terraform_data.migration_task_validation]
}

run "reject_mutable_migrator_image" {
  command = plan
  variables {
    migration_task       = true
    migration_task_image = "ghcr.io/honua-io/honua-server:nightly-aot"
  }
  expect_failures = [var.migration_task_image]
}

run "manual_skip_allowed_without_migration_task" {
  command = plan
  variables {
    additional_env = { HONUA_SKIP_MIGRATIONS = "false" }
  }
}
