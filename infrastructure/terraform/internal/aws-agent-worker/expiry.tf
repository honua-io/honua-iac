# Independent of the controller, command queues and worker launch execution.
# These are predefined runtime operations, not an infrastructure provisioner.
locals {
  reaper_name = "${local.name}-expiry"
  reaper_arn  = "arn:aws:states:${var.region}:${var.account_id}:stateMachine:${local.reaper_name}"
  task_arns   = "${replace(var.cluster_arn, ":cluster/", ":task/")}/*"
  list_expired = {
    Cluster = var.cluster_arn, Family = local.name, LaunchType = "FARGATE", DesiredStatus = "RUNNING", MaxResults = 100
  }
}

resource "aws_iam_role" "reaper" {
  name = local.reaper_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "states.amazonaws.com" },
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id },
    ArnEquals = { "aws:SourceArn" = local.reaper_arn } } }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "reaper" {
  role = aws_iam_role.reaper.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ListTasks requires wildcard resources when no container instance is used.
      { Effect = "Allow", Action = "ecs:ListTasks", Resource = "*",
      Condition = { ArnEquals = { "ecs:cluster" = var.cluster_arn } } },
      { Effect = "Allow", Action = ["ecs:StopTask", "ecs:DescribeTasks"], Resource = local.task_arns,
        Condition = { ArnEquals = { "ecs:cluster" = var.cluster_arn }, StringEquals = {
          "aws:ResourceTag/honua-agent-attempt"   = var.attempt_id
          "aws:ResourceTag/honua-agent-candidate" = var.candidate_digest
      } } }
    ]
  })
}

resource "aws_sfn_state_machine" "reaper" {
  name       = local.reaper_name
  role_arn   = aws_iam_role.reaper.arn
  type       = "STANDARD"
  depends_on = [aws_iam_role_policy.reaper]
  definition = jsonencode({
    StartAt = "CheckExpiry", TimeoutSeconds = 300
    States = {
      CheckExpiry = {
        Type    = "Choice"
        Choices = [{ Variable = "$$.State.EnteredTime", TimestampGreaterThanEquals = local.expires_at, Next = "ListTasks" }]
        Default = "NotExpired"
      }
      NotExpired = { Type = "Fail", Error = "AttemptNotExpired" }
      ListTasks = {
        Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:listTasks"
        Parameters = local.list_expired, ResultPath = "$.page", Next = "StopTasks"
      }
      ListNextPage = {
        Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:listTasks"
        Parameters = merge(local.list_expired, { "NextToken.$" = "$.page.NextToken" })
        ResultPath = "$.page", Next = "StopTasks"
      }
      StopTasks = {
        Type         = "Map", ItemsPath = "$.page.TaskArns", MaxConcurrency = 1, ResultPath = null, Next = "HasMore"
        ItemSelector = { "taskArn.$" = "$$.Map.Item.Value" }
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }, StartAt = "StopTask"
          States = {
            StopTask = {
              Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:stopTask", ResultPath = null, Next = "WaitForStop"
              Parameters = { Cluster = var.cluster_arn, "Task.$" = "$.taskArn", Reason = "Agent attempt absolute expiry" }
            }
            WaitForStop = { Type = "Wait", Seconds = 5, Next = "ObserveTask" }
            ObserveTask = {
              Type       = "Task", Resource = "arn:aws:states:::aws-sdk:ecs:describeTasks", ResultPath = "$.observed", Next = "Stopped"
              Parameters = { Cluster = var.cluster_arn, "Tasks.$" = "States.Array($.taskArn)" }
            }
            Stopped = {
              Type = "Choice"
              Choices = [
                { Variable = "$.observed.Failures[0]", IsPresent = true, Next = "Unobserved" },
                { Variable = "$.observed.Tasks[0].LastStatus", StringEquals = "STOPPED", Next = "Confirmed" }
              ]
              Default = "WaitForStop"
            }
            Unobserved = { Type = "Fail", Error = "CleanupNotObserved" }
            Confirmed  = { Type = "Succeed" }
          }
        }
      }
      HasMore = {
        Type = "Choice"
        Choices = [{ And = [
          { Variable = "$.page.NextToken", IsPresent = true },
          { Variable = "$.page.NextToken", IsNull = false },
          { Not = { Variable = "$.page.NextToken", StringEquals = "" } }
        ], Next = "ListNextPage" }]
        Default = "Complete"
      }
      Complete = { Type = "Succeed" }
    }
  })
  tags = local.tags
}

resource "aws_scheduler_schedule_group" "reaper" {
  name = local.reaper_name
  tags = local.tags
}

resource "aws_sqs_queue" "reaper_dead" {
  name                      = "${local.reaper_name}-dlq"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
  tags                      = local.tags
}

resource "aws_sqs_queue_policy" "reaper_tls" {
  queue_url = aws_sqs_queue.reaper_dead.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Deny", Principal = "*", Action = "sqs:*", Resource = aws_sqs_queue.reaper_dead.arn,
    Condition = { Bool = { "aws:SecureTransport" = "false" } } }]
  })
}

resource "aws_iam_role" "schedule" {
  name = "${local.name}-schedule"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "scheduler.amazonaws.com" },
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id },
    ArnEquals = { "aws:SourceArn" = aws_scheduler_schedule_group.reaper.arn } } }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "schedule" {
  role = aws_iam_role.schedule.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "states:StartExecution", Resource = aws_sfn_state_machine.reaper.arn },
      { Effect = "Allow", Action = "sqs:SendMessage", Resource = aws_sqs_queue.reaper_dead.arn }
    ]
  })
}

resource "aws_scheduler_schedule" "reaper" {
  name                         = local.reaper_name
  group_name                   = aws_scheduler_schedule_group.reaper.name
  schedule_expression          = "rate(1 minute)"
  schedule_expression_timezone = "UTC"
  start_date                   = local.expires_at
  end_date                     = timeadd(local.expires_at, "24h")
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_sfn_state_machine.reaper.arn
    role_arn = aws_iam_role.schedule.arn
    input    = "{}"
    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 2
    }
    dead_letter_config { arn = aws_sqs_queue.reaper_dead.arn }
  }
  depends_on = [aws_iam_role_policy.schedule]
}

resource "aws_cloudwatch_metric_alarm" "reaper" {
  for_each            = toset(["ExecutionsFailed", "ExecutionsTimedOut", "ExecutionsAborted"])
  alarm_name          = "${local.reaper_name}-${each.key}"
  alarm_description   = "Agent expiry cleanup failed; preserve liability and investigate retained execution history."
  namespace           = "AWS/States"
  metric_name         = each.key
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.reaper.arn }
  alarm_actions       = [var.cleanup_alarm_topic_arn]
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "reaper_delivery" {
  alarm_name          = "${local.reaper_name}-delivery"
  alarm_description   = "Expiry schedule could not invoke cleanup; inspect its dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.reaper_dead.name }
  alarm_actions       = [var.cleanup_alarm_topic_arn]
  tags                = local.tags
}
