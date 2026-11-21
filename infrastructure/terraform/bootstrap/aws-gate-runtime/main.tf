locals {
  stack_arn      = "arn:aws:cloudformation:us-east-1:${var.member_account_id}:stack/honua-gate-*/*"
  workload_roles = "arn:aws:iam::${var.member_account_id}:role/honua-gate-*"
  # Customer-managed policies a Launch Stack creates (BatchSubmitPolicy). CloudFormation names them
  # <stack>-<logical id>-<suffix>, and the Terraform-owned policies here are all HonuaGate*, so none matches.
  workload_policies = "arn:aws:iam::${var.member_account_id}:policy/honua-gate-*"
  # Gate test Connections (quick-create Connection role, Connection ID gate-*).
  connection_roles = "arn:aws:iam::${var.member_account_id}:role/honua-connection-gate-*"
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
    # DescribeUserPool* is exactly DescribeUserPool, DescribeUserPoolClient and DescribeUserPoolDomain. Launch Stack
    # workloads only read their own pool client; pool lifecycle is CloudFormation's (cognito_lifecycle_actions).
    "cognito-idp:DescribeUserPool*"
  ]
  # Explicit lifecycle and configuration APIs for the service role only; never user-data reads or auth.
  cognito_lifecycle_actions = [
    "cognito-idp:CreateUserPool", "cognito-idp:DeleteUserPool", "cognito-idp:UpdateUserPool",
    "cognito-idp:CreateUserPoolClient", "cognito-idp:DeleteUserPoolClient", "cognito-idp:UpdateUserPoolClient",
    "cognito-idp:CreateUserPoolDomain", "cognito-idp:DeleteUserPoolDomain", "cognito-idp:UpdateUserPoolDomain",
    "cognito-idp:CreateGroup", "cognito-idp:DeleteGroup", "cognito-idp:UpdateGroup",
    "cognito-idp:AdminCreateUser", "cognito-idp:AdminDeleteUser",
    "cognito-idp:AdminAddUserToGroup", "cognito-idp:AdminRemoveUserFromGroup",
    "cognito-idp:GetGroup", "cognito-idp:GetUserPoolMfaConfig", "cognito-idp:SetUserPoolMfaConfig",
    "cognito-idp:TagResource", "cognito-idp:UntagResource", "cognito-idp:ListTagsForResource"
  ]
  protected_controls = {
    Effect = "Deny", Action = "*"
    Resource = [
      aws_cognito_user_pool.gate.arn,
      aws_secretsmanager_secret.idp_admin.arn,
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
      # Such a name would make every generated role match the IdP secret-reader pattern.
      Effect = "Deny", Action = ["cloudformation:CreateStack"], Resource = "arn:aws:cloudformation:us-east-1:${var.member_account_id}:stack/*ExecutionRole*/*"
      }, {
      Effect   = "Allow", Action = ["cloudformation:DescribeStacks", "cloudformation:DescribeStackEvents", "cloudformation:DescribeStackResource", "cloudformation:ListStackResources", "cloudformation:GetTemplate", "cloudformation:GetStackPolicy"]
      Resource = local.stack_arn
      }, {
      # ecs:ListClusters lists cluster ARNs only and takes no resource scope.
      Effect   = "Allow", Action = ["cloudformation:ListStacks", "cloudformation:ValidateTemplate", "cloudformation:GetTemplateSummary", "ecs:ListClusters"]
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
      }, {
      Sid = "SyncIdpCallbacks", Effect = "Allow", Action = "lambda:InvokeFunction", Resource = "arn:aws:lambda:us-east-1:${var.member_account_id}:function:honua-gate-reaper-callbacks"
      }, {
      # Security proofs evaluate a gate role's deployed policies and boundary
      # with request context, without assuming the role, and read its trust
      # policy and boundary (GetRole). Read-only.
      Sid      = "SimulateGateRoles", Effect = "Allow", Action = ["iam:SimulatePrincipalPolicy", "iam:GetContextKeysForPrincipalPolicy", "iam:GetRole"]
      Resource = "arn:aws:iam::${var.member_account_id}:role/honua-gate-*"
      }, {
      Sid = "InspectNetworkOwnership", Effect = "Allow", Action = "ec2:Describe*", Resource = "*"
      }, {
      # A VPC origin holds its name, load balancer and ports, no secrets. A teardown
      # that reports AccessDenied on one must first know whether it still exists
      # and carries HonuaGate=true. A tag condition here would answer a deleted
      # origin with AccessDenied too, so the scope is every origin in the account.
      Sid      = "InspectVpcOrigins", Effect = "Allow", Action = ["cloudfront:GetVpcOrigin", "cloudfront:ListTagsForResource"]
      Resource = "arn:aws:cloudfront::${var.member_account_id}:vpcorigin/*"
      }, {
      Sid = "DenyInspectionContentReads", Effect = "Deny"
      # Metadata inspection must never expose content, even on gate-owned resources.
      Action   = [for action in local.shared_content_read_actions : action if startswith(action, "ec2:Describe")]
      Resource = "*"
      }, {
      Sid      = "InspectKeyOwnership", Effect = "Allow", Action = "kms:ListResourceTags"
      Resource = "arn:aws:kms:us-east-1:${var.member_account_id}:key/*"
      }, {
      # Qualification rows observe the running install. CloudFormation names
      # gate clusters and database instances after the stack; the template names
      # its log groups. Log APIs have no tag condition, so names are the fence.
      # Task definitions stay unreadable (no resource scope): compare the task's
      # taskDefinitionArn with ListStackResources and read it from GetTemplate.
      # Services give rollout and circuit-breaker state for upgrade rows; gate
      # alarms are named after the stack.
      Sid    = "InspectGateRuntime", Effect = "Allow"
      Action = ["ecs:DescribeTasks", "ecs:DescribeServices", "logs:DescribeLogStreams", "logs:FilterLogEvents", "logs:GetLogEvents", "cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmHistory"]
      Resource = [
        "arn:aws:ecs:us-east-1:${var.member_account_id}:task/honua-gate-*-Cluster-*/*",
        "arn:aws:ecs:us-east-1:${var.member_account_id}:service/honua-gate-*-Cluster-*/*",
        "arn:aws:cloudwatch:us-east-1:${var.member_account_id}:alarm:honua-gate-*",
        "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/honua/honua-gate-*",
        "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:aws-waf-logs-honua-gate-*",
        "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/aws/vendedlogs/honua/honua-gate-*",
        "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/aws/rds/instance/honua-gate-*"
      ]
      }, {
      # Config recorder status, rule scope and compliance, log group retention
      # and log delivery wiring are metadata, and GetMetricStatistics returns
      # numbers (heartbeat rows); none of these APIs offers a resource scope.
      # DescribeDeliver* is today exactly DescribeDeliveries, DescribeDeliveryDestinations
      # and DescribeDeliverySources; the wildcard keeps the boundary in quota.
      # Explicit families only: no resource configuration, remediation,
      # aggregator, metric listing or log content reads.
      Sid    = "InspectGateMetadata", Effect = "Allow", Resource = "*"
      Action = ["config:DescribeConfigurationRecorder*", "config:DescribeDeliveryChannel*", "config:DescribeConfigRule*", "config:DescribeComplianceByConfigRule", "logs:DescribeLogGroups", "logs:DescribeDeliver*", "cloudwatch:GetMetricStatistics"]
      }, {
      Sid       = "ListGateTasks", Effect = "Allow", Action = "ecs:ListTasks", Resource = "*"
      Condition = { ArnLike = { "ecs:cluster" = "arn:aws:ecs:us-east-1:${var.member_account_id}:cluster/honua-gate-*-Cluster-*" } }
    }], local.region_controls, local.stack_tag_controls, local.stack_tag_permissions, local.network_cleanup_permissions)
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
    Statement = concat([local.protected_controls, { Effect = "Allow", Action = concat(local.workload_services, local.workload_config_actions), Resource = "*" }, {
      # Gate test Connection roles share this statement to keep the boundary in quota:
      # ssm actions never match a role ARN and sts:AssumeRole never matches a parameter.
      # The task role's own policy also requires the installation tag on the role.
      Effect = "Allow", Action = ["ssm:*", "sts:AssumeRole"], Resource = [local.watchdog_parameters, local.connection_roles]
      }, {
      # A boundary only restricts: PassRole outside gate roles has no allow here,
      # so it stays denied without a separate statement inside the quota.
      Effect    = "Allow", Action = "iam:PassRole", Resource = local.workload_roles
      Condition = { StringEquals = { "iam:PassedToService" = ["ecs-tasks.amazonaws.com", "batch.amazonaws.com", "backup.amazonaws.com", "lambda.amazonaws.com", "vpc-flow-logs.amazonaws.com", "config.amazonaws.com"] } }
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
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(local.service_role_launch_name_denies, var.shared_account ? [local.creation_tag_deny] : [], var.shared_account ? [local.ec2_creation_tag_deny] : [], var.shared_account ? [local.rds_creation_tag_deny] : [], var.shared_account ? [local.rds_creation_name_deny] : [], [for statement in local.named_tag_denies : statement if var.shared_account], var.shared_account ? [local.named_teardown_deny] : [], [for statement in local.trail_teardown_denies : statement if var.shared_account], [for statement in local.delivery_denies : statement if var.shared_account], flatten(local.gate_test_zone_denies), var.shared_account ? [local.alias_teardown_key_deny] : [], local.temporary_subnet_cleanup_denies) })
}
resource "aws_iam_role_policy_attachment" "cloudformation_fences" {
  role       = aws_iam_role.cloudformation.name
  policy_arn = aws_iam_policy.cloudformation_fences.arn
}
# AWS::IAM::ManagedPolicy takes no tags, so a stack's own policy never carries HonuaGate=true: the name fences it
# instead, and the service role's ownership deny exempts the policy lifecycle actions (shared-account.tf). It can only be attached to gate workload roles, which keep the workload boundary.
# A separate managed policy, because the inline policy is at its quota.
resource "aws_iam_policy" "cloudformation_workload_policies" {
  name = "HonuaGateCloudFormationWorkloadPolicies"
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Sid    = "WorkloadManagedPolicies", Effect = "Allow", Resource = local.workload_policies
    Action = ["iam:CreatePolicy", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:ListEntitiesForPolicy"]
  }] })
}
resource "aws_iam_role_policy_attachment" "cloudformation_workload_policies" {
  role       = aws_iam_role.cloudformation.name
  policy_arn = aws_iam_policy.cloudformation_workload_policies.arn
}
resource "aws_iam_role_policy" "cloudformation" {
  name       = "gate-launch-stack"
  role       = aws_iam_role.cloudformation.id
  depends_on = [aws_iam_role_policy_attachment.cloudformation_fences]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([local.protected_controls, { Effect = "Allow", Action = concat(local.workload_services, local.cognito_lifecycle_actions, local.handler_read_actions, ["backup-storage:MountCapsule", local.config_rule_actions]), Resource = "*" }, {
      Effect    = "Allow", Action = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"], Resource = [local.workload_roles, local.connection_roles]
      Condition = { ArnEquals = { "iam:PermissionsBoundary" = aws_iam_policy.workload_boundary.arn } }
      }, {
      Effect = "Allow"
      # iam:*RolePolic* is exactly Get/Put/Delete/Attach/DetachRolePolicy, ListRolePolicies,
      # ListAttachedRolePolicies and UpdateAssumeRolePolicy, written once to keep this inline policy in quota.
      Action   = ["iam:GetRole", "iam:*RolePolic*", "iam:ListRoleTags", "iam:TagRole", "iam:UntagRole", "iam:DeleteRole", "iam:UpdateRoleDescription", "iam:UpdateRole"]
      Resource = [local.workload_roles, local.connection_roles]
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
