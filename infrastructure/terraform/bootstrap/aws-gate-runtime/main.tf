locals {
  stack_arn        = "arn:aws:cloudformation:us-east-1:${var.member_account_id}:stack/honua-gate-*/*"
  workload_roles   = "arn:aws:iam::${var.member_account_id}:role/honua-gate-*"
  service_role_arn = "arn:aws:iam::${var.member_account_id}:role/HonuaGateCloudFormation"
  workload_services = [
    "acm:*", "application-autoscaling:*", "backup:*", "batch:*", "cloudfront:*", "ec2:*",
    "ecs:*", "elasticloadbalancing:*", "lambda:*", "logs:*", "rds:*", "route53:*",
    "s3:*", "secretsmanager:*", "wafv2:*", "ecr:GetAuthorizationToken", "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"
  ]
  protected_controls = {
    Effect = "Deny", Action = ["lambda:*", "logs:*"]
    Resource = [
      "arn:aws:lambda:us-east-1:${var.member_account_id}:function:honua-gate-reaper",
      "arn:aws:lambda:us-east-1:${var.member_account_id}:function:honua-gate-reaper:*",
      "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/aws/lambda/honua-gate-reaper",
      "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/aws/lambda/honua-gate-reaper:*"
    ]
  }
  lane_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
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
    }]
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
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { AWS = sort(tolist(var.lane_principal_arns)) } }]
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
    Statement = [local.protected_controls, { Effect = "Allow", Action = local.workload_services, Resource = "*" }, {
      Effect    = "Allow", Action = "iam:PassRole", Resource = local.workload_roles
      Condition = { StringEquals = { "iam:PassedToService" = ["ecs-tasks.amazonaws.com", "batch.amazonaws.com", "backup.amazonaws.com", "lambda.amazonaws.com", "vpc-flow-logs.amazonaws.com"] } }
      }, {
      Effect = "Deny", NotAction = concat(local.workload_services, ["iam:PassRole"]), Resource = "*"
      }, {
      Effect = "Deny", Action = "iam:PassRole", NotResource = local.workload_roles
    }]
  })
}
resource "aws_iam_role" "cloudformation" {
  name = "HonuaGateCloudFormation"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "cloudformation.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy" "cloudformation" {
  name = "gate-launch-stack"
  role = aws_iam_role.cloudformation.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [local.protected_controls, { Effect = "Allow", Action = local.workload_services, Resource = "*" }, {
      Effect    = "Allow", Action = "iam:CreateRole", Resource = local.workload_roles
      Condition = { ArnEquals = { "iam:PermissionsBoundary" = aws_iam_policy.workload_boundary.arn } }
      }, {
      Effect   = "Allow"
      Action   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags", "iam:TagRole", "iam:UntagRole", "iam:DeleteRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:UpdateAssumeRolePolicy", "iam:UpdateRoleDescription"]
      Resource = local.workload_roles
      }, {
      Effect    = "Allow", Action = "iam:PassRole", Resource = local.workload_roles
      Condition = { StringEquals = { "iam:PassedToService" = ["ecs-tasks.amazonaws.com", "batch.amazonaws.com", "backup.amazonaws.com", "lambda.amazonaws.com", "vpc-flow-logs.amazonaws.com"] } }
      }, {
      Effect    = "Allow", Action = "iam:CreateServiceLinkedRole", Resource = "arn:aws:iam::${var.member_account_id}:role/aws-service-role/*"
      Condition = { StringEquals = { "iam:AWSServiceName" = ["ecs.amazonaws.com", "ecs.application-autoscaling.amazonaws.com", "elasticloadbalancing.amazonaws.com", "rds.amazonaws.com", "batch.amazonaws.com", "backup.amazonaws.com", "vpc-origin.cloudfront.amazonaws.com"] } }
    }]
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
