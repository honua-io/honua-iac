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
  # IAM and KMS reject aws:-prefixed tags, so gate roles and keys never carry
  # the CloudFormation stack-name tag. They do carry the stack's required
  # HonuaGate=true tag, which CloudFormation propagates; the deny applies only
  # when a resource has neither. Gate principals cannot add that tag to a
  # resource they do not already own.
  ownership_condition = {
    StringNotLikeIfExists   = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" }
    StringNotEqualsIfExists = { "aws:ResourceTag/HonuaGate" = "true" }
  }
  # EC2 accepts the reserved stack-name tag on post-create tagging. RDS instead
  # needs the customer request tag plus a gate name, account and region fence.
  creation_tag_actions = concat(["ec2:CreateTags", "rds:AddTagsToResource"], keys(local.named_tag_targets))
  creation_tag_deny = {
    Sid = "CreationTags", Effect = "Deny", Action = ["ec2:CreateTags"], Resource = "*"
    Condition = {
      StringNotLikeIfExists = merge(local.ownership_condition.StringNotLikeIfExists, {
        "aws:RequestTag/aws:cloudformation:stack-name" = "honua-gate-*"
      })
      StringNotEqualsIfExists = local.ownership_condition.StringNotEqualsIfExists
      Null                    = { "ec2:CreateAction" = "true" }
    }
  }
  # EC2 authorizes tag-on-create separately; the resource has no ownership tags yet.
  ec2_creation_tag_deny = {
    Sid = "EC2CreationTags", Effect = "Deny", Action = ["ec2:CreateTags"], Resource = "*"
    Condition = {
      Null                    = { "ec2:CreateAction" = "false" }
      StringNotEqualsIfExists = { "aws:RequestTag/HonuaGate" = "true" }
    }
  }
  rds_gate_arns = [for kind in ["subgrp", "db", "cluster", "pg", "og", "snapshot"] :
    "arn:aws:rds:us-east-1:${var.member_account_id}:${kind}:honua-gate-*"
  ]
  rds_creation_tag_deny = {
    Sid = "RDSCreationTags", Effect = "Deny", Action = "rds:AddTagsToResource", Resource = "*"
    Condition = merge(local.ownership_condition, {
      StringNotEqualsIfExists = merge(local.ownership_condition.StringNotEqualsIfExists, {
        "aws:RequestTag/HonuaGate" = "true"
      })
    })
  }
  rds_creation_name_deny = {
    Sid         = "RDSCreationNames", Effect = "Deny", Action = "rds:AddTagsToResource"
    NotResource = local.rds_gate_arns
  }
  # First tagging precedes ownership. Each API keeps its own name/account/region fence.
  named_tag_targets = {
    "cloudwatch:TagResource" = ["arn:aws:cloudwatch:us-east-1:${var.member_account_id}:alarm:honua-gate-*"]
    "lambda:TagResource"     = ["arn:aws:lambda:us-east-1:${var.member_account_id}:function:honua-gate-*"]
    "logs:TagResource" = [
      "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/honua/honua-gate-*",
      "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/aws/lambda/honua-gate-*"
    ]
  }
  named_tag_denies = concat([{
    Sid = "NamedCreationTags", Effect = "Deny", Action = keys(local.named_tag_targets), Resource = "*"
    Condition = merge(local.ownership_condition, {
      StringNotEqualsIfExists = merge(local.ownership_condition.StringNotEqualsIfExists, {
        "aws:RequestTag/HonuaGate" = "true"
      })
    })
    }], [for action, arns in local.named_tag_targets : {
    Effect = "Deny", Action = action, NotResource = arns
  }])
  temporary_subnet_cleanup_actions = length(var.temporary_cleanup_subnet_group_names) > 0 ? ["rds:DeleteDBSubnetGroup"] : []
  temporary_subnet_cleanup_denies = length(local.temporary_subnet_cleanup_actions) > 0 ? [{
    Sid = "TemporarySubnetCleanup", Effect = "Deny", Action = "rds:DeleteDBSubnetGroup"
    NotResource = [for name in sort(tolist(var.temporary_cleanup_subnet_group_names)) :
      "arn:aws:rds:us-east-1:${var.member_account_id}:subgrp:${name}"
    ]
  }] : []
  # Exact IDs are supplied privately and removed immediately after orphan cleanup.
  network_cleanup_permissions = length(var.temporary_cleanup_vpc_ids) + length(var.temporary_cleanup_gateway_ids) > 0 ? [{
    Sid    = "TemporaryNetworkCleanup", Effect = "Allow"
    Action = ["ec2:DeleteVpc", "ec2:DeleteInternetGateway", "ec2:DetachInternetGateway"]
    Resource = concat(
      [for id in sort(tolist(var.temporary_cleanup_vpc_ids)) : "arn:aws:ec2:us-east-1:${var.member_account_id}:vpc/${id}"],
      [for id in sort(tolist(var.temporary_cleanup_gateway_ids)) : "arn:aws:ec2:us-east-1:${var.member_account_id}:internet-gateway/${id}"]
    )
  }] : []
  # CloudFront cache, origin-request and response-headers policies and origin access controls cannot carry
  # tags, their create calls take no resource and their other calls name a random ID, so neither tag nor
  # name can fence them. Only the service role (CloudFormation acting for a gate stack) may manage them;
  # workload roles keep the full fence. Functions are named, so the name fences them.
  cloudfront_untaggable_creates = ["cloudfront:CreateCachePolicy", "cloudfront:CreateOriginRequestPolicy", "cloudfront:CreateResponseHeadersPolicy"]
  cloudfront_untaggable_arns = concat([
    for type in ["origin-access-control", "cache-policy", "origin-request-policy", "response-headers-policy"] :
    "arn:aws:cloudfront::${var.member_account_id}:${type}/*"
  ], ["arn:aws:cloudfront::${var.member_account_id}:function/honua-gate-*"])
  service_role_unfenced = concat([aws_secretsmanager_secret.idp_client.arn], local.cloudfront_untaggable_arns)
  # The service role keeps account-wide metadata reads. The workload boundary
  # cannot repeat that list and stay inside the managed-policy quota, so its
  # copy exempts allocation calls, named gate buckets, Cognito domain description
  # and the lookup Lambda's four network metadata calls, which have no resource tags.
  service_role_ownership_deny = {
    Sid       = "DenyNonGateChanges", Effect = "Deny", NotResource = local.service_role_unfenced
    NotAction = concat(local.metadata_read_actions, ["s3:*", "ssm:*", "cognito-idp:TagResource", "logs:*LogDelivery", "backup-storage:MountCapsule"], local.shared_creation_actions, local.cloudfront_untaggable_creates, local.creation_tag_actions, local.named_teardown_actions, local.temporary_subnet_cleanup_actions)
    Condition = local.ownership_condition
  }
  # Alias tags are unavailable; failed-create rules may lack ownership tags.
  # Only the service role may remove these resources; name fences still reject foreign resources.
  named_teardown_actions = ["events:RemoveTargets", "events:DeleteRule", "kms:DeleteAlias"]
  named_teardown_deny = {
    Sid = "NamedTeardownFence", Effect = "Deny", Action = local.named_teardown_actions
    NotResource = [
      "arn:aws:events:us-east-1:${var.member_account_id}:rule/honua-gate-*",
      "arn:aws:kms:us-east-1:${var.member_account_id}:alias/honua-gate-*",
      "arn:aws:kms:us-east-1:${var.member_account_id}:key/*"
    ]
  }
  # DeleteAlias authorizes both alias and key. Alias names supply the name fence;
  # the backing key must independently carry the gate ownership tag.
  alias_teardown_key_deny = {
    Sid       = "AliasTeardownKeys", Effect = "Deny", Action = "kms:DeleteAlias"
    Resource  = "arn:aws:kms:us-east-1:${var.member_account_id}:key/*"
    Condition = { StringNotEqualsIfExists = { "aws:ResourceTag/HonuaGate" = "true" } }
  }
  # The gate server repository is Terraform-owned, so it has no stack tag; the
  # boundary allows only pulls on ECR, and registry login (ecr:GetAuth*, exactly
  # GetAuthorizationToken) has no resource. The region wildcard saves quota; the
  # region deny already confines ECR to us-east-1.
  boundary_ownership_deny = {
    Sid       = "DenyNonGateChanges", Effect = "Deny", NotResource = [aws_secretsmanager_secret.idp_client.arn, local.boundary_repository_arn]
    NotAction = concat(["s3:*", "ssm:*", "cognito-idp:DescribeUserPoolDomain", "cognito-idp:TagResource", "ecr:GetAuth*", "ec2:DescribeManagedPrefixLists", "ec2:DescribeAvailabilityZones", "ec2:DescribeSubnets", "ec2:DescribeVpcs"], local.shared_creation_actions)
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
