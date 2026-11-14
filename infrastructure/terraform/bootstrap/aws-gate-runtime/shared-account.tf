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
    "wafv2:CreateIPSet", "wafv2:CreateRegexPatternSet", "iam:CreateRole",
    "iam:CreateServiceLinkedRole", "iam:PassRole"
  ]
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
      Resource = concat(["*"], [for path in sort(tolist(var.protected_ssm_paths)) : "arn:aws:ssm:us-east-1:${var.member_account_id}:parameter${path}"])
    },
    {
      Sid = "DenyNonGateChanges", Effect = "Deny", Resource = "*"
      NotAction = concat(flatten([
        for service in ["acm", "application-autoscaling", "backup", "batch", "cloudfront", "ec2", "ecs", "elasticloadbalancing", "lambda", "logs", "rds", "route53", "secretsmanager", "wafv2", "ecr", "iam"] : [
          "${service}:Get*", "${service}:List*", "${service}:Describe*"
        ]
      ]), ["s3:*"], local.shared_creation_actions)
      Condition = { StringNotLikeIfExists = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" } }
    }
  ] : control if var.shared_account]
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
