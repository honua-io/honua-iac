mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/fixture" }
  }
  mock_resource "aws_sfn_state_machine" {
    defaults = { arn = "arn:aws:states:us-east-1:123456789012:stateMachine:fixture" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-1:123456789012:fixture" }
  }
}

variables {
  region                  = "us-east-1"
  account_id              = "123456789012"
  attempt_id              = "fixture-attempt"
  candidate_digest        = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  issued_epoch            = 1792080000
  lifetime_seconds        = 600
  cluster_arn             = "arn:aws:ecs:us-east-1:123456789012:cluster/isolated-agents"
  subnet_ids              = ["subnet-123abc"]
  security_group_ids      = ["sg-123abc"]
  image_uri               = "123456789012.dkr.ecr.us-east-1.amazonaws.com/agent@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  claim_table_name        = "controller-claims"
  cleanup_alarm_topic_arn = "arn:aws:sns:us-east-1:123456789012:cleanup-alerts"
}

run "isolated_fargate_attempt" {
  command = apply

  assert {
    condition     = aws_ecs_task_definition.worker.requires_compatibilities == toset(["FARGATE"]) && aws_ecs_task_definition.worker.network_mode == "awsvpc"
    error_message = "Test workers must run in Fargate with isolated networking."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].user == "10001:10001" && jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].readonlyRootFilesystem
    error_message = "Worker image must execute as non-root with an immutable root filesystem."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].linuxParameters.capabilities.drop == ["ALL"]
    error_message = "Workers must have no Linux capabilities."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.worker.policy).Statement) == 2 && alltrue([for statement in jsondecode(aws_iam_role_policy.worker.policy).Statement : startswith(statement.Action[0], "sqs:")])
    error_message = "Worker credentials must grant only their own command/reply queue operations."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.worker.definition).States.ClaimAttempt.Parameters.ConditionExpression == "attribute_not_exists(candidateKey)" && !can(jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Retry)
    error_message = "A task crash must not cause another worker to replay an attempt."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Parameters.NetworkConfiguration.AwsvpcConfiguration.AssignPublicIp == "DISABLED" && !can(jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Parameters.Overrides)
    error_message = "Execution input must not override worker image, role or networking."
  }
  assert {
    condition     = output.transport.expiresEpoch == 1792080600 && jsondecode(output.controller_policy).Statement[4].Effect == "Deny" && jsondecode(output.controller_policy).Statement[4].Action == "states:RedriveExecution"
    error_message = "Expiry must not slide and redrive must not bypass the durable claim."
  }
}

run "reject_other_account_cluster" {
  command = plan
  variables {
    cluster_arn = "arn:aws:ecs:us-east-1:999999999999:cluster/other"
  }
  expect_failures = [aws_ecs_task_definition.worker]
}

run "independent_expiry_cleanup" {
  command = apply

  assert {
    condition     = aws_scheduler_schedule.reaper.start_date == "2026-10-15T16:10:00Z" && aws_scheduler_schedule.reaper.end_date == "2026-10-16T16:10:00Z" && aws_scheduler_schedule.reaper.schedule_expression == "rate(1 minute)"
    error_message = "Cleanup must use a fixed expiry and a bounded independent safety window."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.reaper.definition).States.CheckExpiry.Choices[0].TimestampGreaterThanEquals == local.expires_at && jsondecode(aws_sfn_state_machine.reaper.definition).TimeoutSeconds == 300
    error_message = "Cleanup cannot run before expiry or remain unbounded."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.reaper.definition).States.ListTasks.Parameters.Family == "honua-agent-fixture-attempt" && jsondecode(aws_sfn_state_machine.reaper.definition).States.ListTasks.Parameters.LaunchType == "FARGATE" && jsondecode(aws_sfn_state_machine.reaper.definition).States.ListNextPage.Parameters["NextToken.$"] == "$.page.NextToken"
    error_message = "Cleanup must enumerate all pages of the exact attempt family."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.reaper.definition).States.StopTasks.ItemProcessor.States.Stopped.Choices[1].StringEquals == "STOPPED" && jsondecode(aws_sfn_state_machine.reaper.definition).States.StopTasks.ItemProcessor.States.Unobserved.Type == "Fail"
    error_message = "A stop request alone cannot establish cleanup completion."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.reaper.policy).Statement[1].Condition.StringEquals["aws:ResourceTag/honua-agent-attempt"] == var.attempt_id && jsondecode(aws_iam_role_policy.reaper.policy).Statement[1].Condition.StringEquals["aws:ResourceTag/honua-agent-candidate"] == var.candidate_digest && jsondecode(aws_iam_role_policy.reaper.policy).Statement[1].Condition.ArnEquals["ecs:cluster"] == var.cluster_arn
    error_message = "Cleanup mutations require attempt, candidate and cluster ownership."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.reaper.policy).Statement) == 2 && jsondecode(aws_iam_role_policy.reaper.policy).Statement[1].Action == ["ecs:StopTask", "ecs:DescribeTasks"] && alltrue([for alarm in aws_cloudwatch_metric_alarm.reaper : alarm.alarm_actions == toset([var.cleanup_alarm_topic_arn])]) && aws_cloudwatch_metric_alarm.reaper_delivery.alarm_actions == toset([var.cleanup_alarm_topic_arn])
    error_message = "Cleanup authority must remain limited and failure alarms must have a notification destination."
  }
}

run "reject_unbounded_worker_lifetime" {
  command = plan
  variables {
    lifetime_seconds = 86400
  }
  expect_failures = [var.lifetime_seconds]
}

run "reject_foreign_cleanup_notification" {
  command = plan
  variables {
    cleanup_alarm_topic_arn = "arn:aws:sns:us-east-1:999999999999:unmonitored"
  }
  expect_failures = [aws_ecs_task_definition.worker]
}
