output "transport" {
  description = "Per-attempt container command protocol configuration; not qualification evidence."
  value       = local.transport
}

output "mcp_configuration_binding" {
  description = "Reviewed secret/version metadata for backend preflight, never credential bytes. Null is not MCP-ready."
  value       = var.mcp_configuration
}

output "lifecycle" {
  value = {
    state_machine_arn   = aws_sfn_state_machine.worker.arn
    cluster_arn         = var.cluster_arn
    claim_table_name    = var.claim_table_name
    task_definition_arn = aws_ecs_task_definition.worker.arn
    worker_role_arn     = aws_iam_role.worker.arn
    expires_at          = local.expires_at
    claim_key           = local.claim_key
    candidate_claim_key = local.candidate_claim_key
    stopped_key         = local.stopped_key
  }
}

output "controller_policy" {
  description = "Attach only to the trusted controller; never to a worker. Redrive bypasses the launch claim and is denied."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "sqs:SendMessage", Resource = aws_sqs_queue.channel["commands"].arn },
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = aws_sqs_queue.channel["replies"].arn },
      { Effect = "Allow", Action = ["states:StartExecution", "states:DescribeStateMachine"], Resource = aws_sfn_state_machine.worker.arn },
      { Effect = "Allow", Action = ["states:DescribeExecution", "states:StopExecution", "states:GetExecutionHistory"],
      Resource = "arn:aws:states:${var.region}:${var.account_id}:execution:${local.name}:*" },
      { Effect = "Deny", Action = "states:RedriveExecution", Resource = "*" },
      { Effect = "Allow", Action = ["ecs:DescribeTasks", "ecs:StopTask"], Resource = local.task_arns,
        Condition = { ArnEquals = { "ecs:cluster" = var.cluster_arn }, StringEquals = {
          "aws:ResourceTag/honua-agent-attempt"   = var.attempt_id,
          "aws:ResourceTag/honua-agent-candidate" = var.candidate_digest
      } } },
      { Effect = "Allow", Action = "dynamodb:GetItem", Resource = local.table_arn,
      Condition = { "ForAllValues:StringEquals" = { "dynamodb:LeadingKeys" = [local.claim_key, local.candidate_claim_key, local.stopped_key] } } }
    ]
  })
}

output "independent_cleanup" {
  value = {
    state_machine_arn = aws_sfn_state_machine.reaper.arn
    schedule_arn      = aws_scheduler_schedule.reaper.arn
    expires_at        = local.expires_at
    schedule_ends_at  = aws_scheduler_schedule.reaper.end_date
    dead_letter_arn   = aws_sqs_queue.reaper_dead.arn
    alarm_arns        = concat([for alarm in aws_cloudwatch_metric_alarm.reaper : alarm.arn], [aws_cloudwatch_metric_alarm.reaper_delivery.arn])
  }
}
