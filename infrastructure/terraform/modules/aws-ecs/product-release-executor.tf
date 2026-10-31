# Opt-in grants for the product release executor running as this cell's task role.
# The standing update-rollback controller is assumed by the honua-release producer,
# and its boundary denies Environment=cert|demo, so cert cells cannot use it.
# This policy does not create a listener rule and does not assume that role.
variable "product_release_executor" {
  description = "Attach the product release executor policy to this cell's ECS task role. Requires the protected listener rule from deployment_safety or deploy_control_plane. Default false. The release session sets this; a product lane must not apply it."
  type        = bool
  default     = false
}

locals {
  product_release_rule_ready = local.safety_enabled || (local.deploy_control_plane_enabled && local.canary_enabled)
  product_release_service_arns = concat(
    [aws_ecs_service.this.id],
    local.canary_enabled ? [aws_ecs_service.canary[0].id] : [],
  )
  product_release_task_definition_arns = concat(
    ["arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:task-definition/${aws_ecs_task_definition.this.family}:*"],
    local.canary_enabled ? ["arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:task-definition/${aws_ecs_task_definition.canary[0].family}:*"] : [],
    local.migration_task_enabled ? ["arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:task-definition/${aws_ecs_task_definition.migrate[0].family}:*"] : [],
  )
  product_release_migrate_task_definition_arns = local.migration_task_enabled ? [
    "arn:${data.aws_partition.current.partition}:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:task-definition/${aws_ecs_task_definition.migrate[0].family}:*",
  ] : []
  product_release_pass_role_arns = [
    aws_iam_role.task.arn,
    aws_iam_role.task_execution.arn,
  ]
}

resource "terraform_data" "product_release_executor_validation" {
  count = var.product_release_executor ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.product_release_rule_ready
      error_message = "product_release_executor requires the protected listener rule from deployment_safety or deploy_control_plane. This flag does not create that rule and does not grant the standing update-rollback controller."
    }
  }
}

resource "aws_iam_role_policy" "product_release_executor" {
  count = var.product_release_executor ? 1 : 0
  name  = "${local.name}-product-release-executor"
  role  = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "DescribeAndUpdateCellServices"
          Effect    = "Allow"
          Action    = ["ecs:DescribeServices", "ecs:UpdateService"]
          Resource  = local.product_release_service_arns
          Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
        },
        {
          Sid      = "RegisterCellTaskDefinitions"
          Effect   = "Allow"
          Action   = ["ecs:RegisterTaskDefinition"]
          Resource = local.product_release_task_definition_arns
        },
        {
          # DescribeTaskDefinition and DescribeTasks do not support resource-level permissions.
          Sid      = "DescribeTaskState"
          Effect   = "Allow"
          Action   = ["ecs:DescribeTaskDefinition", "ecs:DescribeTasks"]
          Resource = "*"
        },
        {
          Sid       = "PassCellTaskRoles"
          Effect    = "Allow"
          Action    = ["iam:PassRole"]
          Resource  = local.product_release_pass_role_arns
          Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
        },
        {
          Sid      = "ShiftProtectedListenerRule"
          Effect   = "Allow"
          Action   = ["elasticloadbalancing:ModifyRule"]
          Resource = [aws_lb_listener_rule.protected_rollout[0].arn]
        },
        {
          # These describe APIs do not support resource-level permissions.
          Sid      = "DescribeProtectedListenerRule"
          Effect   = "Allow"
          Action   = ["elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeTargetHealth"]
          Resource = "*"
        },
      ],
      local.migration_task_enabled ? [
        {
          Sid       = "RunCellMigrationTask"
          Effect    = "Allow"
          Action    = ["ecs:RunTask"]
          Resource  = local.product_release_migrate_task_definition_arns
          Condition = { ArnEquals = { "ecs:cluster" = aws_ecs_cluster.this.arn } }
        },
      ] : [],
    )
  })

  depends_on = [terraform_data.product_release_executor_validation]
}
