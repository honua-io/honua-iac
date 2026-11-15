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
  metadata_read_actions = flatten([
    for service in ["acm", "application-autoscaling", "backup", "batch", "budgets", "ce", "cloudfront", "cloudtrail", "cloudwatch", "ec2", "ecs", "elasticloadbalancing", "events", "guardduty", "kms", "lambda", "logs", "rds", "route53", "secretsmanager", "sns", "sqs", "wafv2", "ecr", "iam"] : [
      "${service}:Get*", "${service}:List*", "${service}:Describe*"
    ]
  ])
  ownership_condition = {
    StringNotLikeIfExists = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" }
  }
  # The service role keeps account-wide metadata reads. The workload boundary
  # cannot repeat that list and stay inside the managed-policy quota, so its
  # copy exempts only allocation calls and named gate buckets.
  service_role_ownership_deny = {
    Sid       = "DenyNonGateChanges", Effect = "Deny", NotResource = aws_secretsmanager_secret.idp_client.arn
    NotAction = concat(local.metadata_read_actions, ["s3:*"], local.shared_creation_actions)
    Condition = local.ownership_condition
  }
  boundary_ownership_deny = {
    Sid       = "DenyNonGateChanges", Effect = "Deny", NotResource = aws_secretsmanager_secret.idp_client.arn
    NotAction = concat(["s3:*"], local.shared_creation_actions)
    Condition = local.ownership_condition
  }
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
      Sid      = "DenyPrivateParameters", Effect = "Deny", Action = "ssm:*"
      Resource = "*"
    },
    {
      Sid       = "DenyNonGateContentReads", Effect = "Deny", NotResource = aws_secretsmanager_secret.idp_client.arn
      Action    = local.shared_content_read_actions
      Condition = { StringNotLikeIfExists = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" } }
    }
  ] : control if var.shared_account]
  boundary_shared_denies     = concat(local.shared_controls, local.idp_secret_controls, var.shared_account ? [local.boundary_ownership_deny] : [])
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
