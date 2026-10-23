mock_provider "aws" {
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/honua-agent-fixture-attempt:1" }
  }
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

override_resource {
  target = aws_iam_role.worker
  values = { arn = "arn:aws:iam::123456789012:role/honua-agent-fixture-attempt-worker" }
}

override_resource {
  target = aws_iam_role.execution
  values = { arn = "arn:aws:iam::123456789012:role/honua-agent-fixture-attempt-execution" }
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
    condition     = jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].secrets == [] && length(aws_iam_role_policy.mcp_configuration) == 0 && output.mcp_configuration_binding == null
    error_message = "Terminal-only configuration must not introduce secret retrieval permissions."
  }
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
    condition     = jsondecode(aws_sfn_state_machine.worker.definition).States.ClaimAttempt.Parameters.TransactItems[0].Put.ConditionExpression == "attribute_not_exists(candidateKey)" && !can(jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Retry)
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

run "candidate_wide_fencing" {
  command = apply
  assert {
    condition     = jsondecode(aws_sfn_state_machine.worker.definition).States.ClaimAttempt.Resource == "arn:aws:states:::aws-sdk:dynamodb:transactWriteItems" && jsondecode(aws_sfn_state_machine.worker.definition).States.ClaimAttempt.Parameters.TransactItems[1].Put.Item.candidateKey.S == "${var.candidate_digest}/active-worker" && jsondecode(aws_sfn_state_machine.worker.definition).States.ClaimAttempt.Parameters.TransactItems[1].Put.ConditionExpression == "attribute_not_exists(candidateKey) OR #state = :stopped"
    error_message = "Attempt and candidate claims must commit atomically, with no expiry-based takeover."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.worker.definition).States.ClaimAttempt.Next == "RecheckExpiry" && jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Parameters.Count == 1 && jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Parameters.ClientToken == var.attempt_id && jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Resource == "arn:aws:states:::aws-sdk:ecs:runTask"
    error_message = "A claimed attempt rechecks expiry and can launch only one fixed task."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.worker.definition).States.CheckObservation.Choices[7].StringEquals == "STOPPED" && jsondecode(aws_sfn_state_machine.worker.definition).States.CheckObservation.Choices[7].Next == "RecordStopped" && jsondecode(aws_sfn_state_machine.worker.definition).States.CheckObservation.Choices[4].Not.StringEqualsPath == "$.launched.Tasks[0].TaskArn" && jsondecode(aws_sfn_state_machine.worker.definition).States.Unobserved.Type == "Fail"
    error_message = "Missing or foreign observations must not release the candidate; exact STOPPED must be observed."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.worker.definition).States.RecordStopped.Parameters.TransactItems[0].Put.ConditionExpression == "attribute_not_exists(candidateKey)" && jsondecode(aws_sfn_state_machine.worker.definition).States.RecordStopped.Parameters.TransactItems[0].Put.Item.candidateKey.S == "${local.claim_key}/stopped" && jsondecode(aws_sfn_state_machine.worker.definition).States.RecordStopped.Parameters.TransactItems[1].Put.ConditionExpression == "executionArn = :execution AND attemptId = :attempt AND #state = :active" && jsondecode(aws_sfn_state_machine.worker.definition).States.RecordStopped.Parameters.TransactItems[1].Put.ExpressionAttributeValues[":execution"]["S.$"] == "$$.Execution.Id"
    error_message = "The immutable stop record and successor eligibility must commit atomically for the current owner only."
  }
  assert {
    condition     = alltrue([for state in jsondecode(aws_sfn_state_machine.worker.definition).States : !can(state.Retry) && !can(state.Catch)]) && jsondecode(aws_iam_role_policy.lifecycle.policy).Statement[0].Condition.StringEquals["dynamodb:EnclosingOperation"] == "TransactWriteItems" && toset(jsondecode(aws_iam_role_policy.lifecycle.policy).Statement[0].Condition["ForAllValues:StringEquals"]["dynamodb:LeadingKeys"]) == toset([local.claim_key, local.candidate_claim_key, local.stopped_key])
    error_message = "Failures retain the claim; lifecycle permissions cannot rewrite unrelated attempts or call nontransactional writes."
  }
  assert {
    condition     = jsondecode(output.controller_policy).Statement[5].Condition.StringEquals["aws:ResourceTag/honua-agent-attempt"] == var.attempt_id && jsondecode(output.controller_policy).Statement[5].Condition.StringEquals["aws:ResourceTag/honua-agent-candidate"] == var.candidate_digest && jsondecode(aws_iam_role_policy.lifecycle.policy).Statement[1].Condition.DateLessThan["aws:CurrentTime"] == local.expires_at
    error_message = "Normal cleanup may stop only the owned task, while launch authority expires."
  }
  assert {
    condition     = jsondecode(output.controller_policy).Statement[6].Action == "dynamodb:GetItem" && toset(jsondecode(output.controller_policy).Statement[6].Condition["ForAllValues:StringEquals"]["dynamodb:LeadingKeys"]) == toset([local.claim_key, local.candidate_claim_key, local.stopped_key]) && contains(jsondecode(output.controller_policy).Statement[2].Action, "states:DescribeStateMachine")
    error_message = "Controller preflight may inspect only its fixed definition and exact claim records, never release them."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.worker.definition).States.CheckObservationDeadline.Choices[0].TimestampGreaterThanEquals == "2026-10-15T16:15:00Z" && jsondecode(aws_sfn_state_machine.worker.definition).States.CheckObservation.Choices[0].TimestampGreaterThanEquals == local.observation_deadline && jsondecode(aws_sfn_state_machine.worker.definition).States.CheckStopTime.Choices[0].TimestampGreaterThanEquals == local.observation_deadline && jsondecode(aws_sfn_state_machine.worker.definition).States.ObservationExpired.Type == "Fail"
    error_message = "A late execution cannot extend polling or release past the fixed observation window."
  }
}

run "pinned_mcp_configuration" {
  command = apply
  variables {
    mcp_configuration = {
      secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-agent-fixture-attempt-mcp-AbCdEf"
      version_id = "12345678-1234-1234-1234-123456789abc"
    }
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].secrets == [{ name = "HONUA_AGENT_MCP_CONFIG", valueFrom = "${var.mcp_configuration.secret_arn}:::${var.mcp_configuration.version_id}" }] && alltrue([for entry in jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].environment : entry.name != "HONUA_AGENT_MCP_CONFIG"])
    error_message = "Only an explicit secret version reference may enter the task definition, never plaintext configuration."
  }
  assert {
    condition     = aws_iam_role_policy.mcp_configuration[0].role == aws_iam_role.execution.id && length(jsondecode(aws_iam_role_policy.mcp_configuration[0].policy).Statement) == 1 && jsondecode(aws_iam_role_policy.mcp_configuration[0].policy).Statement[0].Action == ["secretsmanager:GetSecretValue"] && jsondecode(aws_iam_role_policy.mcp_configuration[0].policy).Statement[0].Resource == var.mcp_configuration.secret_arn
    error_message = "Secret retrieval must attach only to the execution role and exact secret."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.mcp_configuration[0].policy).Statement[0].Condition.StringEquals == { "secretsmanager:VersionId" = var.mcp_configuration.version_id, "aws:ResourceTag/honua-agent-attempt" = var.attempt_id, "aws:ResourceTag/honua-agent-candidate" = var.candidate_digest } && jsondecode(aws_iam_role_policy.mcp_configuration[0].policy).Statement[0].Condition.DateLessThan["aws:CurrentTime"] == local.expires_at
    error_message = "Retrieval requires the pinned version, owned secret tags and unexpired attempt."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_iam_role_policy.worker.policy).Statement : startswith(statement.Action[0], "sqs:")]) && jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Parameters.PlatformVersion == "1.4.0" && !can(jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Parameters.Overrides)
    error_message = "Application AWS permissions remain queue-only and execution input cannot replace the version-pinned task."
  }
}

run "mcp_customer_key_scope" {
  command = apply
  variables {
    mcp_configuration = {
      secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-agent-fixture-attempt-mcp-AbCdEf"
      version_id  = "12345678-1234-1234-1234-123456789abc"
      kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789abc"
    }
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.mcp_configuration[0].policy).Statement) == 2 && jsondecode(aws_iam_role_policy.mcp_configuration[0].policy).Statement[1].Action == ["kms:Decrypt"] && jsondecode(aws_iam_role_policy.mcp_configuration[0].policy).Statement[1].Resource == var.mcp_configuration.kms_key_arn
    error_message = "A customer key grants only Decrypt on that exact key."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.mcp_configuration[0].policy).Statement[1].Condition.StringEquals == { "kms:ViaService" = "secretsmanager.us-east-1.amazonaws.com", "kms:EncryptionContext:SecretARN" = var.mcp_configuration.secret_arn, "kms:EncryptionContext:SecretVersionId" = var.mcp_configuration.version_id } && jsondecode(aws_iam_role_policy.mcp_configuration[0].policy).Statement[1].Condition.DateLessThan["aws:CurrentTime"] == local.expires_at
    error_message = "Decryption must be through Secrets Manager for the owned secret/version before expiry."
  }
}

run "reject_other_attempt_mcp_secret" {
  command = plan
  variables {
    mcp_configuration = {
      secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-agent-other-attempt-mcp-AbCdEf"
      version_id = "12345678-1234-1234-1234-123456789abc"
    }
  }
  expect_failures = [aws_ecs_task_definition.worker]
}

run "reject_foreign_mcp_secret" {
  command = plan
  variables {
    mcp_configuration = {
      secret_arn = "arn:aws:secretsmanager:us-west-2:999999999999:secret:honua-agent-fixture-attempt-mcp-AbCdEf"
      version_id = "12345678-1234-1234-1234-123456789abc"
    }
  }
  expect_failures = [aws_ecs_task_definition.worker]
}

run "reject_moving_secret_version" {
  command = plan
  variables {
    mcp_configuration = {
      secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-agent-fixture-attempt-mcp-AbCdEf"
      version_id = "AWSCURRENT"
    }
  }
  expect_failures = [var.mcp_configuration]
}

run "reject_foreign_mcp_key" {
  command = plan
  variables {
    mcp_configuration = {
      secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-agent-fixture-attempt-mcp-AbCdEf"
      version_id  = "12345678-1234-1234-1234-123456789abc"
      kms_key_arn = "arn:aws:kms:us-east-1:999999999999:key/12345678-1234-1234-1234-123456789abc"
    }
  }
  expect_failures = [aws_ecs_task_definition.worker]
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

run "all_roles_preserve_operator_boundary" {
  command = apply
  variables {
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/honua-pilot-controller-boundary"
  }
  assert {
    condition     = alltrue([for role in [aws_iam_role.worker, aws_iam_role.execution, aws_iam_role.lifecycle, aws_iam_role.reaper, aws_iam_role.schedule] : role.permissions_boundary == var.permissions_boundary_arn])
    error_message = "Every created role, including independent cleanup and scheduler, must retain the boundary."
  }
}

run "default_boundary_remains_unset" {
  command = apply
  assert {
    condition     = alltrue([for role in [aws_iam_role.worker, aws_iam_role.execution, aws_iam_role.lifecycle, aws_iam_role.reaper, aws_iam_role.schedule] : role.permissions_boundary == null])
    error_message = "Omitted boundary must preserve the existing worker deployment contract."
  }
}

run "reject_foreign_boundary" {
  command = plan
  variables {
    permissions_boundary_arn = "arn:aws:iam::999999999999:policy/other"
  }
  expect_failures = [aws_ecs_task_definition.worker]
}

run "reject_wildcard_boundary" {
  command = plan
  variables {
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/*"
  }
  expect_failures = [var.permissions_boundary_arn]
}
