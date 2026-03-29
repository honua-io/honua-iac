data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "task_execution_runtime" {
  statement {
    sid = "WriteContainerLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  dynamic "statement" {
    for_each = length(local.execution_role_ecr_repository_arns) > 0 ? [1] : []

    content {
      sid       = "AuthorizeEcrPull"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(local.execution_role_ecr_repository_arns) > 0 ? [1] : []

    content {
      sid = "ReadEcrImages"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ]
      resources = local.execution_role_ecr_repository_arns
    }
  }
}

resource "aws_iam_policy" "task_execution_runtime" {
  name        = "${local.name}-task-execution-runtime"
  description = "Least-privilege ECS task execution policy for logs and image pulls"
  policy      = data.aws_iam_policy_document.task_execution_runtime.json
}

resource "aws_iam_role_policy_attachment" "task_execution_runtime" {
  role       = aws_iam_role.task_execution.name
  policy_arn = aws_iam_policy.task_execution_runtime.arn
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
  tags               = local.tags
}

resource "aws_iam_policy" "secrets" {
  name        = "${local.name}-secrets"
  description = "Allow ECS task to read Honua secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = compact([
          aws_secretsmanager_secret.db_connection.arn,
          aws_secretsmanager_secret.admin_password.arn,
          aws_secretsmanager_secret.connection_encryption_master_key.arn,
          local.redis_enabled ? aws_secretsmanager_secret.redis_connection[0].arn : null
        ])
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [local.kms_key_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "task_secrets" {
  role       = aws_iam_role.task_execution.name
  policy_arn = aws_iam_policy.secrets.arn
}

resource "aws_iam_policy" "task_app_storage" {
  count = var.app_storage_enabled ? 1 : 0

  name        = "${local.name}-task-app-storage"
  description = "Allow ECS task to read and write Honua application storage"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.app_storage[0].arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = ["${aws_s3_bucket.app_storage[0].arn}/${local.app_storage_prefix}/*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "task_app_storage" {
  count = var.app_storage_enabled ? 1 : 0

  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.task_app_storage[0].arn
}
