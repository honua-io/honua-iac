output "transport" {
  description = "Per-attempt container command protocol configuration; not qualification evidence."
  value       = local.transport
}

output "lifecycle" {
  value = {
    state_machine_arn   = aws_sfn_state_machine.worker.arn
    task_definition_arn = aws_ecs_task_definition.worker.arn
    worker_role_arn     = aws_iam_role.worker.arn
    expires_at          = local.expires_at
    claim_key           = local.claim_key
  }
}

output "controller_policy" {
  description = "Attach only to the trusted controller; never to a worker. Redrive bypasses the launch claim and is denied."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "sqs:SendMessage", Resource = aws_sqs_queue.channel["commands"].arn },
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = aws_sqs_queue.channel["replies"].arn },
      { Effect = "Allow", Action = "states:StartExecution", Resource = aws_sfn_state_machine.worker.arn },
      { Effect = "Allow", Action = ["states:DescribeExecution", "states:StopExecution", "states:GetExecutionHistory"],
      Resource = "arn:aws:states:${var.region}:${var.account_id}:execution:${local.name}:*" },
      { Effect = "Deny", Action = "states:RedriveExecution", Resource = "*" }
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
