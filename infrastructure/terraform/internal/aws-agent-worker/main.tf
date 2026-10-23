provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}

locals {
  name                = "honua-agent-${var.attempt_id}"
  expires_epoch       = var.issued_epoch + var.lifetime_seconds
  expires_at          = timeadd("1970-01-01T00:00:00Z", "${local.expires_epoch}s")
  claim_key           = "${var.candidate_digest}/worker/${var.attempt_id}"
  candidate_claim_key = "${var.candidate_digest}/active-worker"
  stopped_key         = "${local.claim_key}/stopped"
  table_arn           = "arn:aws:dynamodb:${var.region}:${var.account_id}:table/${var.claim_table_name}"
  image_repo          = split("@", split("amazonaws.com/", var.image_uri)[1])[0]
  tags = {
    ManagedBy               = "terraform"
    Owner                   = "honua-agent-e2e"
    "honua-agent-attempt"   = var.attempt_id
    "honua-agent-candidate" = var.candidate_digest
    "honua-agent-expires"   = tostring(local.expires_epoch)
  }
  transport = {
    commandQueueUrl = aws_sqs_queue.channel["commands"].url
    replyQueueUrl   = aws_sqs_queue.channel["replies"].url
    attemptId       = var.attempt_id
    expiresEpoch    = local.expires_epoch
  }
  task_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ecs-tasks.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:ecs:${var.region}:${var.account_id}:*" }
      }
    }]
  })
}

resource "aws_sqs_queue" "dead" {
  name                      = "${local.name}-dead.fifo"
  fifo_queue                = true
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
  tags                      = local.tags
}

resource "aws_sqs_queue" "channel" {
  for_each                    = toset(["commands", "replies"])
  name                        = "${local.name}-${each.key}.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  sqs_managed_sse_enabled     = true
  visibility_timeout_seconds  = 330
  message_retention_seconds   = 86400
  receive_wait_time_seconds   = 2
  redrive_policy              = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dead.arn, maxReceiveCount = 3 })
  tags                        = local.tags
}

resource "aws_sqs_queue_policy" "tls" {
  for_each  = aws_sqs_queue.channel
  queue_url = each.value.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Deny", Principal = "*", Action = "sqs:*", Resource = each.value.arn,
    Condition = { Bool = { "aws:SecureTransport" = "false" } } }]
  })
}

resource "aws_iam_role" "worker" {
  permissions_boundary = var.permissions_boundary_arn
  name                 = "${local.name}-worker"
  assume_role_policy   = local.task_trust
  tags                 = local.tags
}

resource "aws_iam_role_policy" "worker" {
  role = aws_iam_role.worker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage"], Resource = aws_sqs_queue.channel["commands"].arn },
      { Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.channel["replies"].arn }
    ]
  })
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/honua/agent-e2e/${var.attempt_id}"
  retention_in_days = 30
  tags              = local.tags
}

resource "aws_iam_role" "execution" {
  permissions_boundary = var.permissions_boundary_arn
  name                 = "${local.name}-execution"
  assume_role_policy   = local.task_trust
  tags                 = local.tags
}

resource "aws_iam_role_policy" "execution" {
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"],
      Resource = "arn:aws:ecr:${var.region}:${var.account_id}:repository/${local.image_repo}" },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.worker.arn}:*" }
    ]
  })
}

resource "aws_ecs_task_definition" "worker" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  task_role_arn            = aws_iam_role.worker.arn
  execution_role_arn       = aws_iam_role.execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  volume { name = "workspace" }
  volume { name = "journal" }
  container_definitions = jsonencode([{
    name                   = "worker", image = var.image_uri, essential = true, user = "10001:10001"
    readonlyRootFilesystem = true, privileged = false
    linuxParameters        = { initProcessEnabled = true, capabilities = { drop = ["ALL"] } }
    command                = ["python", "-I", "/app/agent_e2e_container_entry.py"]
    environment = [
      { name = "HONUA_AGENT_TRANSPORT", value = jsonencode(local.transport) },
      { name = "AWS_DEFAULT_REGION", value = var.region }
    ]
    secrets = var.mcp_configuration == null ? [] : [
      { name = "HONUA_AGENT_MCP_CONFIG", valueFrom = "${var.mcp_configuration.secret_arn}:::${var.mcp_configuration.version_id}" }
    ]
    mountPoints = [
      { sourceVolume = "workspace", containerPath = "/workspace", readOnly = false },
      { sourceVolume = "journal", containerPath = "/journal", readOnly = false }
    ]
    logConfiguration = { logDriver = "awslogs", options = {
      "awslogs-group" = aws_cloudwatch_log_group.worker.name, "awslogs-region" = var.region, "awslogs-stream-prefix" = "worker"
    } }
  }])
  tags = local.tags
  lifecycle {
    precondition {
      condition     = var.permissions_boundary_arn == null ? true : startswith(var.permissions_boundary_arn, "arn:aws:iam::${var.account_id}:policy/")
      error_message = "Worker permissions boundary must belong to the reviewed account."
    }
    precondition {
      condition     = startswith(var.image_uri, "${var.account_id}.dkr.ecr.${var.region}.amazonaws.com/") && startswith(var.cluster_arn, "arn:aws:ecs:${var.region}:${var.account_id}:cluster/")
      error_message = "Worker image and cluster must belong to the reviewed account and region."
    }
    precondition {
      condition     = startswith(var.cleanup_alarm_topic_arn, "arn:aws:sns:${var.region}:${var.account_id}:")
      error_message = "Cleanup alarms require a monitored topic in the reviewed account and region."
    }
    precondition {
      condition = var.mcp_configuration == null ? true : (
        can(regex("^arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${local.name}-mcp-[A-Za-z0-9]{6}$", var.mcp_configuration.secret_arn)) &&
        (var.mcp_configuration.kms_key_arn == null ? true : startswith(var.mcp_configuration.kms_key_arn, "arn:aws:kms:${var.region}:${var.account_id}:key/"))
      )
      error_message = "MCP configuration must belong to this exact attempt/account/region; its optional KMS key must be in the same account and region."
    }
  }
}

resource "aws_iam_role" "lifecycle" {
  permissions_boundary = var.permissions_boundary_arn
  name                 = "${local.name}-lifecycle"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "states.amazonaws.com" },
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id },
    ArnEquals = { "aws:SourceArn" = "arn:aws:states:${var.region}:${var.account_id}:stateMachine:${local.name}" } } }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "lifecycle" {
  role = aws_iam_role.lifecycle.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "dynamodb:PutItem", Resource = local.table_arn,
        Condition = { "ForAllValues:StringEquals" = { "dynamodb:LeadingKeys" = [local.claim_key, local.candidate_claim_key, local.stopped_key] },
      StringEquals = { "dynamodb:EnclosingOperation" = "TransactWriteItems" } } },
      { Effect = "Allow", Action = "ecs:RunTask", Resource = aws_ecs_task_definition.worker.arn,
      Condition = { ArnEquals = { "ecs:cluster" = var.cluster_arn }, DateLessThan = { "aws:CurrentTime" = local.expires_at } } },
      { Effect = "Allow", Action = "ecs:TagResource", Resource = "${replace(var.cluster_arn, ":cluster/", ":task/")}/*",
      Condition = { StringEquals = { "ecs:CreateAction" = "RunTask" } } },
      { Effect = "Allow", Action = ["ecs:DescribeTasks", "ecs:StopTask"],
        Resource = local.task_arns, Condition = { ArnEquals = { "ecs:cluster" = var.cluster_arn }, StringEquals = {
      "aws:ResourceTag/honua-agent-attempt" = var.attempt_id, "aws:ResourceTag/honua-agent-candidate" = var.candidate_digest } } },
      { Effect = "Allow", Action = "iam:PassRole", Resource = [aws_iam_role.worker.arn, aws_iam_role.execution.arn],
      Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } } }
    ]
  })
}

resource "aws_sfn_state_machine" "worker" {
  name     = local.name
  role_arn = aws_iam_role.lifecycle.arn
  type     = "STANDARD"
  depends_on = [aws_iam_role_policy.lifecycle, aws_iam_role_policy.worker, aws_iam_role_policy.execution, aws_iam_role_policy.mcp_configuration,
  aws_scheduler_schedule.reaper, aws_cloudwatch_metric_alarm.reaper, aws_cloudwatch_metric_alarm.reaper_delivery]
  definition = jsonencode(local.worker_lifecycle)
  tags       = local.tags
}
