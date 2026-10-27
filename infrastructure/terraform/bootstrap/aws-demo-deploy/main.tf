# Apply role for demo.honua.io (honua-demo-infra#104).
#
# honua-demo-infra .github/workflows/terraform.yml applies stacks/aws on merge
# to trunk, in the protected `demo` GitHub environment, with this role. It is
# the only non-human identity that may change the demo, so a rollback is a
# one-line PR (lambda_alias_version) instead of an AWS CLI call.
#
# Built with components/aws-github-oidc (existing provider, exact environment
# subject, certification policy off). Trust: only
# repo:honua-io/honua-demo-infra:environment:demo. That environment must have
# required reviewers and a trunk-only deployment-branch policy; GitHub puts the
# environment or the ref in `sub`, never both.
#
# Permissions: what applying stacks/aws needs, scoped to the demo's names
# (<name_prefix>-*), its region, its data bucket, its hosted zone and its one
# state object. Denies that hold whatever else is attached:
#   - any region but the demo region and us-east-1 (IAM, CloudFront, ACM for
#     CloudFront, the state bucket);
#   - deleting the database, the data bucket, a secret, the VPC or the zone:
#     a plan that needs one of those fails at apply and goes through
#     break-glass instead;
#   - any IAM user, access key or login profile, role chaining, and touching
#     any *-gha role (this one, the drift roles, the cert role);
#   - any state object other than the demo's;
#   - the operator-owned key ring.

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "demo" {
  name         = var.hosted_zone_name
  private_zone = false
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.demo_region
  prefix     = var.name_prefix
  bucket_arn = "arn:aws:s3:::${var.state_bucket_name}"
  state_arn  = "${local.bucket_arn}/${var.state_key}"

  data_bucket_arns = [
    "arn:aws:s3:::${var.data_bucket_name_prefix}*",
    "arn:aws:s3:::${var.data_bucket_name_prefix}*/*",
  ]
  secret_arns = [
    for prefix in var.secret_name_prefixes : "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${prefix}*"
  ]
  denied_secret_arns = [
    for name in var.denied_secret_names : "arn:aws:secretsmanager:*:${local.account_id}:secret:${name}*"
  ]
  repository_arns = [
    for name in var.image_repository_names : "arn:aws:ecr:${local.region}:${local.account_id}:repository/${name}"
  ]

  # Control-plane reads for refresh (same surface as the demo drift role).
  reads = [
    "acm:DescribeCertificate", "acm:GetCertificate", "acm:ListCertificates", "acm:ListTagsForCertificate",
    "apigateway:GET",
    "budgets:ListTagsForResource", "budgets:ViewBudget",
    "cloudfront:Describe*", "cloudfront:Get*", "cloudfront:List*",
    "cloudwatch:Describe*", "cloudwatch:GetDashboard", "cloudwatch:ListDashboards", "cloudwatch:ListTagsForResource",
    "ec2:Describe*", "ec2:GetInstanceUefiData",
    "ecr:Describe*", "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy", "ecr:ListTagsForResource",
    "elasticache:Describe*", "elasticache:List*",
    "geo:Describe*", "geo:List*",
    "iam:Get*", "iam:List*",
    "kms:Describe*", "kms:List*",
    "lambda:Get*", "lambda:List*",
    "logs:Describe*", "logs:ListTagsForResource", "logs:ListTagsLogGroup",
    "rds:Describe*", "rds:ListTagsForResource",
    "route53:Get*", "route53:List*",
    "s3:GetBucket*", "s3:GetAccelerateConfiguration", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration",
    "s3:GetReplicationConfiguration", "s3:ListAllMyBuckets", "s3:ListBucket",
    "secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy", "secretsmanager:ListSecrets", "secretsmanager:ListSecretVersionIds",
  ]

  destructive_denies = [
    "rds:DeleteDBInstance",
    "rds:DeleteDBCluster",
    "rds:DeleteDBSnapshot",
    "s3:DeleteBucket",
    "secretsmanager:DeleteSecret",
    "ec2:DeleteVpc",
    "route53:DeleteHostedZone",
  ]

  lambda_managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole",
  ]
}

module "oidc" {
  source = "../../components/aws-github-oidc"

  create_oidc_provider       = false
  existing_oidc_provider_arn = var.oidc_provider_arn

  github_owner                 = "honua-io"
  github_repository            = "honua-demo-infra"
  github_oidc_subjects         = var.oidc_subjects
  role_name                    = var.role_name
  cert_permissions_enabled     = false
  max_session_duration_seconds = var.max_session_duration_seconds

  name_prefix = "honua-demo-infra"
  environment = "deploy"
  purpose     = "demo-apply"
  tags        = { Owner = "honua-platform" }
}

data "aws_iam_policy_document" "apply" {
  statement {
    sid       = "Read"
    effect    = "Allow"
    actions   = local.reads
    resources = ["*"]
  }

  # --- state: the demo object and its lock file only ------------------------
  statement {
    sid       = "DemoState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.state_arn, "${local.state_arn}.tflock"]
  }

  # --- compute ----------------------------------------------------------------
  statement {
    sid     = "DemoLambda"
    effect  = "Allow"
    actions = ["lambda:*"]
    resources = [
      "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.prefix}-*",
      "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.prefix}-*:*",
    ]
  }

  # Lambda checks that the caller can pull the container image it is given.
  statement {
    sid       = "ServingImagePullAndRepositoryPolicy"
    effect    = "Allow"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:SetRepositoryPolicy", "ecr:DeleteRepositoryPolicy"]
    resources = local.repository_arns
  }

  # --- identity: the demo's own roles and policies ---------------------------
  statement {
    sid    = "DemoRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:DetachRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.prefix}-*"]
  }

  statement {
    sid       = "DemoRolesAttachOnlyKnownPolicies"
    effect    = "Allow"
    actions   = ["iam:AttachRolePolicy"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.prefix}-*"]
    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values   = concat(local.lambda_managed_policy_arns, ["arn:aws:iam::${local.account_id}:policy/${local.prefix}-*"])
    }
  }

  statement {
    sid    = "DemoManagedPolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:policy/${local.prefix}-*"]
  }

  statement {
    sid       = "PassDemoRolesToTheirServices"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${local.prefix}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com", "ec2.amazonaws.com", "rds.amazonaws.com"]
    }
  }

  # --- network, database, cache (region-bound; denies below cover deletion) ---
  statement {
    sid       = "DemoNetworkDatabaseCache"
    effect    = "Allow"
    actions   = ["ec2:*", "rds:*", "elasticache:*"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }

  # --- edge: API Gateway, CloudFront, ACM, Route 53 --------------------------
  statement {
    sid       = "DemoApiGateway"
    effect    = "Allow"
    actions   = ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE", "apigateway:TagResource", "apigateway:UntagResource"]
    resources = ["arn:aws:apigateway:${local.region}::/*"]
  }

  statement {
    sid       = "DemoEdge"
    effect    = "Allow"
    actions   = ["cloudfront:*", "acm:*"]
    resources = ["*"]
  }

  statement {
    sid       = "DemoZoneRecords"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets", "route53:ChangeTagsForResource"]
    resources = [data.aws_route53_zone.demo.arn]
  }

  # --- data, secrets, observability, cost ------------------------------------
  statement {
    sid       = "DemoDataBucket"
    effect    = "Allow"
    actions   = ["s3:*"]
    resources = local.data_bucket_arns
  }

  statement {
    sid       = "DemoSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:*"]
    resources = local.secret_arns
  }

  statement {
    sid    = "DemoLogsAndAlarms"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
      "logs:TagResource", "logs:UntagResource", "logs:TagLogGroup", "logs:UntagLogGroup",
      "logs:PutMetricFilter", "logs:DeleteMetricFilter", "logs:AssociateKmsKey", "logs:DisassociateKmsKey",
      "logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries",
      "logs:PutResourcePolicy", "logs:DescribeResourcePolicies",
      "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:TagResource", "cloudwatch:UntagResource",
      "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }

  statement {
    sid     = "DemoGeocoderAndBudget"
    effect  = "Allow"
    actions = ["geo:*", "budgets:ModifyBudget", "budgets:TagResource", "budgets:UntagResource"]
    resources = [
      "arn:aws:geo:${local.region}:${local.account_id}:place-index/${local.prefix}-*",
      "arn:aws:budgets::${local.account_id}:budget/${local.prefix}-*",
    ]
  }

  # --- denies: hold whatever else is ever attached ---------------------------
  statement {
    sid       = "DenyOtherRegions"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = distinct([local.region, "us-east-1"])
    }
  }

  statement {
    sid       = "DenyDataDestruction"
    effect    = "Deny"
    actions   = local.destructive_denies
    resources = ["*"]
  }

  statement {
    sid    = "DenyIdentityEscalation"
    effect = "Deny"
    actions = [
      "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "iam:UpdateLoginProfile",
      "iam:CreateOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint", "iam:DeleteOpenIDConnectProvider",
      "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary",
      "sts:AssumeRole",
    ]
    resources = ["*"]
  }

  statement {
    sid           = "DenyIamWritesOutsideTheDemo"
    effect        = "Deny"
    actions       = ["iam:Create*", "iam:Delete*", "iam:Put*", "iam:Update*", "iam:Attach*", "iam:Detach*", "iam:Tag*", "iam:Untag*", "iam:SetDefaultPolicyVersion", "iam:PassRole"]
    not_resources = ["arn:aws:iam::${local.account_id}:role/${local.prefix}-*", "arn:aws:iam::${local.account_id}:policy/${local.prefix}-*"]
  }

  statement {
    sid       = "DenyGhaRoles"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = ["arn:aws:iam::${local.account_id}:role/*-gha"]
  }

  # No object outside the demo state object, its lock file and the data
  # bucket: other states (bootstrap, cert, candidate-preflight) stay untouched.
  statement {
    sid           = "DenyOtherObjects"
    effect        = "Deny"
    actions       = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    not_resources = [local.state_arn, "${local.state_arn}.tflock", "arn:aws:s3:::${var.data_bucket_name_prefix}*/*"]
  }

  statement {
    sid       = "DenyOperatorOwnedSecrets"
    effect    = "Deny"
    actions   = ["secretsmanager:*"]
    resources = local.denied_secret_arns
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "demo-apply"
  role   = module.oidc.role_name
  policy = data.aws_iam_policy_document.apply.json
}
