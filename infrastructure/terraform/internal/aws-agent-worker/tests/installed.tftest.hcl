mock_provider "aws" {
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/honua-agent-fixed-slot:1" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/fixture" }
  }
  mock_resource "aws_sfn_state_machine" {
    defaults = { arn = "arn:aws:states:us-east-1:123456789012:stateMachine:fixture" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-1:123456789012:fixture", url = "https://sqs.us-east-1.amazonaws.com/123456789012/fixture.fifo" }
  }
}
variables {
  region                  = "us-east-1"
  account_id              = "123456789012"
  attempt_id              = "fixed-slot"
  candidate_digest        = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  issued_epoch            = 1792080000
  lifetime_seconds        = 600
  cluster_arn             = "arn:aws:ecs:us-east-1:123456789012:cluster/isolated-agents"
  subnet_ids              = ["subnet-123abc"]
  security_group_ids      = ["sg-123abc"]
  image_uri               = "123456789012.dkr.ecr.us-east-1.amazonaws.com/agent@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  claim_table_name        = "controller-claims"
  cleanup_alarm_topic_arn = "arn:aws:sns:us-east-1:123456789012:cleanup-alerts"
  installed_slot = {
    runtime_id = "runtime_01", slot_id = "fixed-slot", original_funding_expires_epoch = 1792166400, max_execution_seconds = 6000
  }
  mcp_configuration = {
    secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-agent-fixed-slot-mcp-AbCdEf"
    version_id = "12345678-1234-1234-1234-123456789abc"
  }
}

run "installed_slot_protocol" {
  command = apply
  assert {
    condition = output.transport == {
      schemaVersion       = 2, mode = "installed-slot", candidateKey = var.candidate_digest,
      runtimeId           = "runtime_01", slotId = "fixed-slot", originalFundingExpiresEpoch = 1792166400,
      maxExecutionSeconds = 6000, commandQueueUrl = aws_sqs_queue.channel["commands"].url, replyQueueUrl = aws_sqs_queue.channel["replies"].url
    }
    error_message = "Installed transport must contain only fixed installation bindings, never an epoch/turn credential."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].environment == [{ name = "HONUA_AGENT_TRANSPORT", value = jsonencode(local.transport) }, { name = "AWS_DEFAULT_REGION", value = var.region }] && jsondecode(aws_ecs_task_definition.worker.container_definitions)[0].secrets == [{ name = "HONUA_AGENT_MCP_CONFIG", valueFrom = "${var.mcp_configuration.secret_arn}:::${var.mcp_configuration.version_id}" }]
    error_message = "The task must retain exactly its static transport, reviewed AWS region and one immutable private MCP configuration."
  }
  assert {
    condition     = output.installed_worker_slot.schema == "honua.installed-worker-slot/v1" && output.installed_worker_slot.runtimeId == "runtime_01" && output.installed_worker_slot.claimTable == var.claim_table_name && output.installed_worker_slot.image == var.image_uri && output.installed_worker_slot.mcpSecret == { secretArn = var.mcp_configuration.secret_arn, versionId = var.mcp_configuration.version_id } && output.installed_worker_slot.definitionDigest == "sha256:${sha256(jsonencode(jsondecode(aws_sfn_state_machine.worker.definition)))}"
    error_message = "The controller descriptor must bind the actual fixed definition, immutable secret, image and claim table."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Parameters["ClientToken.$"] == "$.executionId" && jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Parameters["StartedBy.$"] == "$.executionId" && !can(jsondecode(aws_sfn_state_machine.worker.definition).States.RunWorker.Parameters.Overrides) && alltrue([for state in jsondecode(aws_sfn_state_machine.worker.definition).States : !can(state.Retry) && !can(state.Catch)])
    error_message = "One native execution must identify the sole launch without retries or arbitrary task overrides."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.worker.definition).StartAt == "ValidateInstalledInput" && strcontains(jsondecode(aws_sfn_state_machine.worker.definition).States.ValidateInstalledInput.Choices[0].Condition, "$count($keys($states.input)) = 11") && jsondecode(aws_sfn_state_machine.worker.definition).States.CheckExecutionName.Choices[0].StringEqualsPath == "$._slot.hash.name" && jsondecode(aws_sfn_state_machine.worker.definition).TimeoutSeconds == 6300
    error_message = "Closed native input, deterministic execution name and the bounded execution clock must precede any claim or launch."
  }
}

run "installed_claim_and_retirement_authority" {
  command = apply
  assert {
    condition     = jsondecode(aws_sfn_state_machine.worker.definition).States.ClaimInstalledExecution.Parameters.TransactItems[0].Put.ConditionExpression == "attribute_not_exists(candidateKey)" && jsondecode(aws_sfn_state_machine.worker.definition).States.ClaimInstalledExecution.Parameters.TransactItems[1].Update.ConditionExpression == "attribute_not_exists(activeExecutionId)" && jsondecode(aws_sfn_state_machine.worker.definition).States.ClaimInstalledExecution.Parameters.TransactItems[1].Update.Key.candidateKey.S == "${var.candidate_digest}/runtime/runtime_01/slot/fixed-slot"
    error_message = "A permanent execution and an exclusively occupied slot must be claimed atomically without TTL takeover."
  }
  assert {
    condition     = length(jsondecode(aws_sfn_state_machine.worker.definition).States.RecordStopped.Parameters.TransactItems) == 1 && !can(jsondecode(aws_sfn_state_machine.worker.definition).States.RecordStopped.Parameters.TransactItems[0].Update) && endswith(jsondecode(aws_sfn_state_machine.worker.definition).States.RecordStopped.Parameters.TransactItems[0].Put.Item.candidateKey["S.$"], "/stopped', $.executionId)")
    error_message = "An observed stop may append evidence but must never release a slot or certify retirement."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.lifecycle.policy).Statement[0].Action == "dynamodb:PutItem" && !strcontains(jsonencode(jsondecode(aws_iam_role_policy.lifecycle.policy).Statement), "/retired") && alltrue([for statement in jsondecode(aws_iam_role_policy.lifecycle.policy).Statement : !strcontains(jsonencode(statement.Action), "DeleteItem")])
    error_message = "The lifecycle may not retire or delete execution claims."
  }
  assert {
    condition     = jsondecode(output.controller_policy).Statement[7].Action == "dynamodb:PutItem" && jsondecode(output.controller_policy).Statement[7].Condition.StringEquals["dynamodb:EnclosingOperation"] == "TransactWriteItems" && jsondecode(output.controller_policy).Statement[8].Condition["ForAllValues:StringEquals"]["dynamodb:LeadingKeys"] == ["${var.candidate_digest}/runtime/runtime_01/slot/fixed-slot"] && length(jsondecode(output.controller_policy).Statement) == 9
    error_message = "Only the controller gets transaction-enclosed retirement and exact head/slot fencing authority."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.worker.policy).Statement) == 2 && alltrue([for statement in jsondecode(aws_iam_role_policy.worker.policy).Statement : startswith(statement.Action[0], "sqs:")])
    error_message = "Installed workers must remain queue-only and cannot write claims or retire themselves."
  }
}

run "installed_independent_expiry" {
  command = apply
  assert {
    condition     = aws_scheduler_schedule.reaper.start_date == null && aws_scheduler_schedule.reaper.end_date == "2026-10-17T16:00:00Z" && jsondecode(aws_sfn_state_machine.reaper.definition).StartAt == "ListTasks" && jsondecode(aws_sfn_state_machine.reaper.definition).TimeoutSeconds == 300
    error_message = "Installed cleanup must run throughout installation, and stop after the fixed safety window."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.reaper.definition).States.StopTasks.ItemProcessor.StartAt == "InspectTask" && jsondecode(aws_sfn_state_machine.reaper.definition).States.StopTasks.ItemProcessor.States.InspectTask.Parameters.Include == ["TAGS"] && strcontains(jsondecode(aws_sfn_state_machine.reaper.definition).States.StopTasks.ItemProcessor.States.CheckIdentity.Choices[0].Condition, "TaskDefinitionArn") && strcontains(jsondecode(aws_sfn_state_machine.reaper.definition).States.StopTasks.ItemProcessor.States.CheckExecutionExpiry.Choices[1].Condition, "honua-agent-execution-expires")
    error_message = "Each cleanup must positively inspect the exact task revision and execution expiry before stopping."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.reaper.policy, "dynamodb:") && jsondecode(aws_sfn_state_machine.reaper.definition).States.StopTasks.ItemProcessor.States.Unobserved.Type == "Fail" && jsondecode(aws_sfn_state_machine.reaper.definition).States.StopTasks.ItemProcessor.States.CheckIdentity.Default == "Unobserved"
    error_message = "Missing or foreign task metadata must remain unknown; cleanup cannot release or retire slots."
  }
}

run "reject_installed_slot_rebinding" {
  command = plan
  variables {
    installed_slot = { runtime_id = "runtime_01", slot_id = "another-slot", original_funding_expires_epoch = 1792166400, max_execution_seconds = 6000 }
  }
  expect_failures = [aws_ecs_task_definition.worker]
}
run "reject_installed_funding_extension" {
  command = plan
  variables {
    installed_slot = { runtime_id = "runtime_01", slot_id = "fixed-slot", original_funding_expires_epoch = 1792771200, max_execution_seconds = 6000 }
  }
  expect_failures = [aws_ecs_task_definition.worker]
}
run "reject_installed_without_private_mcp" {
  command = plan
  variables { mcp_configuration = null }
  expect_failures = [aws_ecs_task_definition.worker]
}
run "reject_unbounded_installed_execution" {
  command = plan
  variables {
    installed_slot = { runtime_id = "runtime_01", slot_id = "fixed-slot", original_funding_expires_epoch = 1792166400, max_execution_seconds = 6001 }
  }
  expect_failures = [var.installed_slot]
}
