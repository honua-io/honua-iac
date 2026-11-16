locals {
  stack_arn        = "arn:aws:cloudformation:us-east-1:${var.member_account_id}:stack/honua-gate-*/*"
  workload_roles   = "arn:aws:iam::${var.member_account_id}:role/honua-gate-*"
  service_role_arn = "arn:aws:iam::${var.member_account_id}:role/HonuaGateCloudFormation"
  # A Launch Stack watchdog keeps its state and mode in two String parameters.
  watchdog_parameters = "arn:aws:ssm:us-east-1:${var.member_account_id}:parameter/honua/honua-gate-*/watchdog/*"
  workload_services = [
    "acm:*", "application-autoscaling:*", "backup:*", "batch:*", "budgets:*", "ce:*",
    "cloudfront:*", "cloudtrail:*", "cloudwatch:*", "ec2:*", "ecs:*", "elasticloadbalancing:*",
    "events:*", "guardduty:*", "kms:*", "lambda:*", "logs:*", "rds:*", "route53:*",
    "s3:*", "secretsmanager:*", "sns:*", "sqs:*", "wafv2:*",
    # Image pulls. Each ECR wildcard matches exactly one action (GetAuthorizationToken,
    # GetDownloadUrlForLayer, BatchCheckLayerAvailability); it keeps the boundary in quota.
    "ecr:GetAuth*", "ecr:BatchGetImage", "ecr:GetDownload*", "ecr:BatchCheck*",
    # Explicit lifecycle and configuration APIs; never user-data reads or auth.
    "cognito-idp:CreateUserPool", "cognito-idp:DeleteUserPool", "cognito-idp:UpdateUserPool",
    "cognito-idp:CreateUserPoolClient", "cognito-idp:DeleteUserPoolClient", "cognito-idp:UpdateUserPoolClient",
    "cognito-idp:CreateUserPoolDomain", "cognito-idp:DeleteUserPoolDomain", "cognito-idp:UpdateUserPoolDomain",
    "cognito-idp:CreateGroup", "cognito-idp:DeleteGroup", "cognito-idp:UpdateGroup",
    "cognito-idp:AdminCreateUser", "cognito-idp:AdminDeleteUser",
    "cognito-idp:AdminAddUserToGroup", "cognito-idp:AdminRemoveUserFromGroup",
    # DescribeUserPool* is exactly DescribeUserPool, DescribeUserPoolClient and DescribeUserPoolDomain.
    "cognito-idp:DescribeUserPool*",
    "cognito-idp:GetGroup", "cognito-idp:GetUserPoolMfaConfig", "cognito-idp:SetUserPoolMfaConfig",
    "cognito-idp:TagResource", "cognito-idp:UntagResource", "cognito-idp:ListTagsForResource"
  ]
  protected_controls = {
    Effect = "Deny", Action = "*"
    Resource = [
      aws_cognito_user_pool.gate.arn,
      # Reserve the reaper namespace, including qualified functions and log streams.
      # Combining these deny-only resources keeps the managed boundary within quota.
      "arn:aws:lambda:us-east-1:${var.member_account_id}:function:honua-gate-reaper*",
      "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/aws/lambda/honua-gate-reaper*"
    ]
  }
  lane_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Sid       = "GateStacksOnly", Effect = "Allow"
      Action    = ["cloudformation:CreateStack", "cloudformation:UpdateStack", "cloudformation:DeleteStack"]
      Resource  = local.stack_arn
      Condition = { StringEquals = { "cloudformation:RoleArn" = local.service_role_arn } }
      }, {
      Effect   = "Allow", Action = ["cloudformation:DescribeStacks", "cloudformation:DescribeStackEvents", "cloudformation:ListStackResources", "cloudformation:GetTemplate", "cloudformation:GetStackPolicy"]
      Resource = local.stack_arn
      }, {
      Effect   = "Allow", Action = ["cloudformation:ListStacks", "cloudformation:ValidateTemplate", "cloudformation:GetTemplateSummary"]
      Resource = "*"
      }, {
      Effect    = "Allow", Action = "iam:PassRole", Resource = local.service_role_arn
      Condition = { StringEquals = { "iam:PassedToService" = "cloudformation.amazonaws.com" } }
      }, {
      Sid       = "GateTemplates", Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject"], Resource = local.template_objects
      Condition = { StringEquals = { "aws:ResourceAccount" = var.member_account_id } }
      }, {
      Sid = "GateImagePush", Effect = "Allow", Action = local.image_push_actions, Resource = local.server_repository_arn
      }, {
      Sid = "RegistryLogin", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*"
    }], local.region_controls, local.stack_tag_controls, local.stack_tag_permissions)
  })
}
resource "aws_iam_policy" "lane_boundary" {
  name   = "HonuaGateLaneBoundary"
  policy = local.lane_policy
}
resource "aws_iam_role" "lane" {
  name                 = "HonuaGateLane"
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.lane_boundary.arn
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { AWS = sort(tolist(setunion(var.lane_principal_arns, [aws_iam_role.release_actions.arn]))) } }]
  })
}
resource "aws_iam_role_policy" "lane" {
  name   = "gate-stacks-only"
  role   = aws_iam_role.lane.id
  policy = local.lane_policy
}
resource "aws_iam_policy" "workload_boundary" {
  name = "HonuaGateWorkloadBoundary"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([local.protected_controls, { Effect = "Allow", Action = local.workload_services, Resource = "*" }, {
      Effect = "Allow", Action = "ssm:*", Resource = local.watchdog_parameters
      }, {
      # A boundary only restricts: PassRole outside gate roles has no allow here,
      # so it stays denied without a separate statement inside the quota.
      Effect    = "Allow", Action = "iam:PassRole", Resource = local.workload_roles
      Condition = { StringEquals = { "iam:PassedToService" = ["ecs-tasks.amazonaws.com", "batch.amazonaws.com", "backup.amazonaws.com", "lambda.amazonaws.com", "vpc-flow-logs.amazonaws.com"] } }
    }], local.region_controls, local.boundary_shared_denies, local.launch_name_denies)
  })
}
resource "aws_iam_role" "cloudformation" {
  name = "HonuaGateCloudFormation"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "cloudformation.amazonaws.com" } }]
  })
}
# The name fences and the creation-tag deny live in an attached managed policy: the inline policy is at its
# 10,240-character quota. The inline policy waits for the attachment so an apply never leaves the role
# without the fences.
resource "aws_iam_policy" "cloudformation_fences" {
  name   = "HonuaGateCloudFormationFences"
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(local.launch_name_denies, var.shared_account ? [local.creation_tag_deny, local.named_teardown_deny] : []) })
}
resource "aws_iam_role_policy_attachment" "cloudformation_fences" {
  role       = aws_iam_role.cloudformation.name
  policy_arn = aws_iam_policy.cloudformation_fences.arn
}
resource "aws_iam_role_policy" "cloudformation" {
  name       = "gate-launch-stack"
  role       = aws_iam_role.cloudformation.id
  depends_on = [aws_iam_role_policy_attachment.cloudformation_fences]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([local.protected_controls, { Effect = "Allow", Action = local.workload_services, Resource = "*" }, {
      Effect    = "Allow", Action = "iam:CreateRole", Resource = local.workload_roles
      Condition = { ArnEquals = { "iam:PermissionsBoundary" = aws_iam_policy.workload_boundary.arn } }
      }, {
      Effect   = "Allow"
      Action   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags", "iam:TagRole", "iam:UntagRole", "iam:DeleteRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:UpdateAssumeRolePolicy", "iam:UpdateRoleDescription"]
      Resource = local.workload_roles
      }, {
      # events: a stack's EventBridge rule delivers findings through its own role.
      Effect    = "Allow", Action = "iam:PassRole", Resource = local.workload_roles
      Condition = { StringEquals = { "iam:PassedToService" = ["ecs-tasks.amazonaws.com", "batch.amazonaws.com", "backup.amazonaws.com", "lambda.amazonaws.com", "vpc-flow-logs.amazonaws.com", "events.amazonaws.com"] } }
      }, {
      Effect    = "Allow", Action = "iam:CreateServiceLinkedRole", Resource = "arn:aws:iam::${var.member_account_id}:role/aws-service-role/*"
      Condition = { StringEquals = { "iam:AWSServiceName" = ["ecs.amazonaws.com", "ecs.application-autoscaling.amazonaws.com", "elasticloadbalancing.amazonaws.com", "rds.amazonaws.com", "batch.amazonaws.com", "backup.amazonaws.com", "guardduty.amazonaws.com", "vpc-origin.cloudfront.amazonaws.com"] } }
      }, {
      Sid = "ReadGateTemplates", Effect = "Allow", Action = "s3:GetObject", Resource = local.template_objects
      }, {
      Sid = "WatchdogParameters", Effect = "Allow", Action = "ssm:*", Resource = local.watchdog_parameters
    }], local.region_controls, local.service_role_shared_denies)
  })
}
output "lane_role_arn" {
  value       = aws_iam_role.lane.arn
  sensitive   = true
  description = "Private lane credential target; never publish in PR text."
}
output "cloudformation_role_arn" {
  value       = aws_iam_role.cloudformation.arn
  sensitive   = true
  description = "Pass explicitly as RoleARN for every gate stack mutation."
}
output "workload_boundary_arn" {
  value       = aws_iam_policy.workload_boundary.arn
  sensitive   = true
  description = "Required PermissionsBoundary on every Launch Stack IAM role."
}
