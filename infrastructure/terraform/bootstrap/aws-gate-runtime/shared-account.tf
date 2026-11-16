locals {
  region_controls = var.shared_account ? [{
    Sid       = "DenyOtherRegions", Effect = "Deny", Resource = "*"
    NotAction = ["iam:*", "route53:*", "cloudfront:*"]
    Condition = { StringNotEquals = { "aws:RequestedRegion" = "us-east-1" } }
  }] : []

  stack_tag_controls = var.shared_account ? [{
    Sid       = "RequireGateCostTag", Effect = "Deny"
    Action    = ["cloudformation:CreateStack", "cloudformation:UpdateStack"]
    Resource  = local.stack_arn
    Condition = { StringNotEqualsIfExists = { "aws:RequestTag/HonuaGate" = "true" } }
  }] : []

  stack_tag_permissions = var.shared_account ? [{
    Sid       = "TagGateStacks", Effect = "Allow"
    Action    = "cloudformation:TagResource"
    Resource  = local.stack_arn
    Condition = { StringEquals = { "cloudformation:CreateAction" = ["CreateStack", "UpdateStack"] } }
  }] : []

  # These APIs allocate resources; they do not authorize changing an existing
  # resource merely because its name starts with honua-gate-. Unsupported
  # ownership checks fail closed, including tag-changing APIs.
  shared_creation_actions = [
    "acm:RequestCertificate", "backup:CreateBackupVault", "backup:CreateBackupPlan",
    "cognito-idp:CreateUserPool",
    "batch:CreateComputeEnvironment", "batch:CreateJobQueue", "batch:RegisterJobDefinition",
    "cloudfront:CreateDistribution", "cloudfront:CreateDistributionWithTags",
    "cloudfront:CreateOriginAccessControl", "cloudfront:CreateFunction", "cloudfront:CreateVpcOrigin",
    "ec2:AllocateAddress", "ec2:CreateVpc", "ec2:CreateSubnet", "ec2:CreateRouteTable",
    "ec2:CreateInternetGateway", "ec2:CreateNatGateway", "ec2:CreateSecurityGroup",
    "ec2:CreateVpcEndpoint", "ec2:CreateNetworkAcl", "ec2:CreateFlowLogs", "ec2:RunInstances",
    "ecs:CreateCluster", "ecs:CreateService", "ecs:RegisterTaskDefinition",
    "elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup",
    "lambda:CreateFunction", "logs:CreateLogGroup",
    "rds:CreateDBInstance", "rds:CreateDBCluster", "rds:CreateDBSubnetGroup",
    "rds:CreateDBParameterGroup", "rds:CreateDBClusterParameterGroup",
    "route53:CreateHostedZone", "secretsmanager:CreateSecret", "wafv2:CreateWebACL",
    "wafv2:CreateIPSet", "wafv2:CreateRegexPatternSet",
    "budgets:ModifyBudget", "ce:CreateAnomalyMonitor", "ce:CreateAnomalySubscription",
    "cloudtrail:CreateTrail", "cloudwatch:PutMetricAlarm", "cloudwatch:PutCompositeAlarm",
    "events:PutRule", "events:PutTargets", "guardduty:CreateDetector",
    "kms:CreateKey", "kms:CreateAlias", "sns:CreateTopic", "sqs:CreateQueue",
    "iam:CreateRole", "iam:CreateServiceLinkedRole", "iam:PassRole"
  ]
  metadata_read_actions = concat([for action in flatten([
    for service in ["acm", "application-autoscaling", "backup", "batch", "budgets", "ce", "cloudfront", "cloudtrail", "cloudwatch", "ec2", "ecs", "elasticloadbalancing", "events", "guardduty", "kms", "lambda", "logs", "rds", "route53", "secretsmanager", "sns", "sqs", "wafv2", "ecr", "iam"] : [
      "${service}:Get*", "${service}:List*", "${service}:Describe*"
    ]
    ]) : action if !contains(local.shared_content_read_actions, action)], [
    "cognito-idp:DescribeUserPool", "cognito-idp:DescribeUserPoolDomain",
    "cognito-idp:GetGroup", "cognito-idp:GetUserPoolMfaConfig", "cognito-idp:ListTagsForResource"
  ])
  ownership_condition = {
    StringNotLikeIfExists = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" }
  }
  # The service role keeps account-wide metadata reads. The workload boundary
  # cannot repeat that list and stay inside the managed-policy quota, so its
  # copy exempts allocation calls, named gate buckets and Cognito domain
  # description, which has no resource-level authorization.
  service_role_ownership_deny = {
    Sid       = "DenyNonGateChanges", Effect = "Deny", NotResource = aws_secretsmanager_secret.idp_client.arn
    NotAction = concat(local.metadata_read_actions, ["s3:*", "ssm:*", "cognito-idp:TagResource"], local.shared_creation_actions)
    Condition = local.ownership_condition
  }
  # The gate server repository is Terraform-owned, so it has no stack tag; the
  # boundary allows only pulls on ECR, and registry login (ecr:GetAuth*, exactly
  # GetAuthorizationToken) has no resource. The region wildcard saves quota; the
  # region deny already confines ECR to us-east-1.
  boundary_ownership_deny = {
    Sid       = "DenyNonGateChanges", Effect = "Deny", NotResource = [aws_secretsmanager_secret.idp_client.arn, local.boundary_repository_arn]
    NotAction = concat(["s3:*", "ssm:*", "cognito-idp:DescribeUserPoolDomain", "cognito-idp:TagResource", "ecr:GetAuth*"], local.shared_creation_actions)
    Condition = local.ownership_condition
  }
  # Only metadata exceptions need a separate content deny; all other content
  # APIs are already fenced by DenyNonGateChanges. Fully denied metadata
  # families are also omitted from its exceptions to fit the inline quota.
  shared_controls = [for control in [
    {
      Sid         = "DenyOtherBuckets", Effect = "Deny", Action = "s3:*"
      NotResource = ["arn:aws:s3:::honua-gate-*", "arn:aws:s3:::honua-gate-*/*"]
    },
    {
      Sid      = "DenyState", Effect = "Deny", Action = "s3:*"
      Resource = flatten([for bucket in sort(tolist(var.protected_state_buckets)) : ["arn:aws:s3:::${bucket}", "arn:aws:s3:::${bucket}/*"]])
    },
    {
      # Only a gate stack's watchdog state and mode parameters are reachable.
      # PutParameter creates and updates in one call, so the name fences it.
      Sid         = "DenyPrivateParameters", Effect = "Deny", Action = "ssm:*"
      NotResource = local.watchdog_parameters
    },
    {
      Sid = "DenyNonGateContentReads", Effect = "Deny", NotResource = aws_secretsmanager_secret.idp_client.arn
      Action = [for action in local.shared_content_read_actions : action if anytrue([
        for pattern in local.metadata_read_actions : can(regex("^${replace(pattern, "*", ".*")}$", action))
      ])]
      Condition = { StringNotLikeIfExists = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" } }
    },
    {
      # CreateUserPool requires tagging before a pool has ownership tags. Only
      # CloudFormation can supply the reserved creation tag used by this fence.
      Sid = "PoolTags", Effect = "Deny", Action = "cognito-idp:TagResource", Resource = "*"
      Condition = { StringNotLikeIfExists = {
        "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*"
        "aws:RequestTag/aws:cloudformation:stack-name"  = "honua-gate-*"
      } }
    }
  ] : control if var.shared_account]
  # The ownership NotAction deny already covers every content-read action.
  # Keep the explicit content list only in the metadata-reading service policy
  # to avoid duplicating it inside the 6,144-character managed boundary.
  # The boundary allows SSM only on watchdog parameters, so it needs no
  # separate SSM deny either; that also keeps it inside the managed quota.
  boundary_shared_denies     = concat([for control in local.shared_controls : control if !contains(["DenyNonGateContentReads", "DenyPrivateParameters"], control.Sid)], local.idp_secret_controls, var.shared_account ? [local.boundary_ownership_deny] : [])
  service_role_shared_denies = concat(local.shared_controls, local.idp_secret_controls, var.shared_account ? [local.service_role_ownership_deny] : [])
  # PutRule, PutTargets, PutMetricAlarm, PutCompositeAlarm and ModifyBudget are
  # create and update in one API, so a missing stack tag cannot gate them.
  # Names do. The reaper schedule and shared budget match the gate prefix and
  # need their own denies.
  launch_name_denies = [
    {
      Sid    = "NameFence", Effect = "Deny"
      Action = ["events:PutRule", "events:PutTargets", "cloudwatch:PutMetricAlarm", "cloudwatch:PutCompositeAlarm", "budgets:ModifyBudget"]
      NotResource = [
        "arn:aws:events:us-east-1:${var.member_account_id}:rule/honua-gate-*",
        "arn:aws:cloudwatch:us-east-1:${var.member_account_id}:alarm:honua-gate-*",
        "arn:aws:budgets::${var.member_account_id}:budget/honua-gate-*"
      ]
    },
    {
      Sid      = "ReaperRule", Effect = "Deny", Action = "events:*"
      Resource = "arn:aws:events:us-east-1:${var.member_account_id}:rule/honua-gate-nightly-reaper"
    },
    {
      Sid      = "DenySharedBudget", Effect = "Deny", Action = "budgets:*"
      Resource = "arn:aws:budgets::${var.member_account_id}:budget/honua-gate-shared-monthly"
    }
  ]
}

resource "aws_budgets_budget" "shared" {
  count        = var.shared_account ? 1 : 0
  name         = "honua-gate-shared-monthly"
  budget_type  = "COST"
  limit_amount = "300"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "TagKeyValue"
    values = ["user:HonuaGate$true"]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
