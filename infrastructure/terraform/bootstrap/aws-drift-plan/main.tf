# Plan-only OIDC roles for nightly drift plans (honua-iac#320,
# honua-demo-infra#103).
#
#   demo_infra    honua-demo-infra .github/workflows/drift-plan.yml: plans every
#                 stack under stacks/ against demo.honua.io.
#   iac_bootstrap honua-iac .github/workflows/bootstrap-drift-plan.yml: plans the
#                 bootstrap roots that hold state in this account.
#
# Both federate through components/aws-github-oidc (existing provider, exact
# environment subjects, cert policy off) and get only what `terraform plan`
# needs: control-plane reads, their own state prefix, and writes to that
# prefix's *.tflock objects for S3-native locking. A Deny on every other action
# is the backstop, so attaching a broader policy later still cannot make either
# role write.
#
# Reading state and refreshing aws_secretsmanager_secret_version both expose
# secret values, so the demo role may read exactly the Terraform-managed demo
# secrets and is denied the operator-owned ones.

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  bucket_arn = "arn:aws:s3:::${var.state_bucket_name}"

  tags = {
    Owner = "honua-platform"
  }

  # Bucket-level S3 reads. Never s3:Get* on arn:aws:s3:::* -- that wildcard
  # matches object ARNs too, i.e. every object in the account.
  s3_bucket_reads = [
    "s3:GetBucket*",
    "s3:GetAccelerateConfiguration",
    "s3:GetAnalyticsConfiguration",
    "s3:GetEncryptionConfiguration",
    "s3:GetIntelligentTieringConfiguration",
    "s3:GetInventoryConfiguration",
    "s3:GetLifecycleConfiguration",
    "s3:GetMetricsConfiguration",
    "s3:GetReplicationConfiguration",
    "s3:ListAllMyBuckets",
    # HeadBucket is authorised as s3:ListBucket (bucket action; keys only).
    "s3:ListBucket",
  ]

  # Control-plane reads for every resource type in the demo stacks' state
  # (module aws-serverless plus the stack's own resources). Data-plane reads
  # (log events, secret values, objects, image layers, registry tokens) are
  # not here.
  demo_control_plane_reads = [
    "acm:DescribeCertificate",
    "acm:GetCertificate",
    "acm:ListCertificates",
    "acm:ListTagsForCertificate",
    "apigateway:GET",
    "batch:Describe*",
    "batch:List*",
    "budgets:ListTagsForResource",
    "budgets:ViewBudget",
    "cloudfront:Describe*",
    "cloudfront:Get*",
    "cloudfront:List*",
    "cloudwatch:Describe*",
    "cloudwatch:GetDashboard",
    "cloudwatch:ListDashboards",
    "cloudwatch:ListTagsForResource",
    "codeartifact:Describe*",
    "codeartifact:GetDomainPermissionsPolicy",
    "codeartifact:GetRepositoryPermissionsPolicy",
    "codeartifact:List*",
    "ec2:Describe*",
    "ec2:GetInstanceUefiData",
    "ecr:Describe*",
    "ecr:GetLifecyclePolicy",
    "ecr:GetRepositoryPolicy",
    "ecr:ListTagsForResource",
    "elasticache:Describe*",
    "elasticache:List*",
    "events:Describe*",
    "events:List*",
    "geo:Describe*",
    "geo:List*",
    "iam:Get*",
    "iam:List*",
    "kms:Describe*",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:List*",
    "lambda:Get*",
    "lambda:List*",
    "logs:Describe*",
    "logs:ListTagsForResource",
    "logs:ListTagsLogGroup",
    "rds:Describe*",
    "rds:ListTagsForResource",
    "redshift:DescribeClusterSubnetGroups",
    "route53:Get*",
    "route53:List*",
    "scheduler:Get*",
    "scheduler:List*",
    "secretsmanager:DescribeSecret",
    "secretsmanager:GetResourcePolicy",
    "secretsmanager:ListSecrets",
    "secretsmanager:ListSecretVersionIds",
    "sns:GetSubscriptionAttributes",
    "sns:GetTopicAttributes",
    "sns:ListSubscriptionsByTopic",
    "sns:ListTagsForResource",
  ]

  # The bootstrap roots in this account manage IAM only.
  bootstrap_control_plane_reads = [
    "iam:Get*",
    "iam:List*",
  ]

  state_object_actions = ["s3:GetObject"]
  lock_object_actions  = ["s3:PutObject", "s3:DeleteObject"]

  demo_object_reads = ["s3:GetObject", "s3:GetObjectAcl", "s3:GetObjectTagging", "s3:GetObjectVersion"]

  demo_readable_object_arns = length(var.demo_readable_object_arns) > 0 ? var.demo_readable_object_arns : [
    "arn:aws:s3:::honua-demo-data-${local.account_id}/manifest/*",
  ]

  demo_secret_arn = "arn:aws:secretsmanager:${var.demo_region}:${local.account_id}:secret:${var.demo_secret_name_prefix}*"
  demo_denied_secret_arns = [
    for name in var.demo_denied_secret_names : "arn:aws:secretsmanager:*:${local.account_id}:secret:${name}*"
  ]

  roles = {
    demo_infra = {
      role_name   = "honua-demo-infra-drift-gha"
      repository  = "honua-demo-infra"
      subjects    = var.demo_infra_oidc_subjects
      purpose     = "demo-drift-plan"
      state_glob  = "${local.bucket_arn}/${var.demo_state_key_prefix}*"
      lock_glob   = "${local.bucket_arn}/${var.demo_state_key_prefix}*.tflock"
      reads       = concat(local.demo_control_plane_reads, local.s3_bucket_reads)
      object_arns = local.demo_readable_object_arns
      secrets     = true
    }
    iac_bootstrap = {
      role_name   = "honua-iac-bootstrap-drift-gha"
      repository  = "honua-iac"
      subjects    = var.iac_bootstrap_oidc_subjects
      purpose     = "bootstrap-drift-plan"
      state_glob  = "${local.bucket_arn}/${var.bootstrap_state_key_prefix}*"
      lock_glob   = "${local.bucket_arn}/${var.bootstrap_state_key_prefix}*.tflock"
      reads       = local.bootstrap_control_plane_reads
      object_arns = []
      secrets     = false
    }
  }
}

module "oidc" {
  source   = "../../components/aws-github-oidc"
  for_each = local.roles

  create_oidc_provider       = false
  existing_oidc_provider_arn = var.oidc_provider_arn

  github_owner                 = "honua-io"
  github_repository            = each.value.repository
  github_oidc_subjects         = each.value.subjects
  role_name                    = each.value.role_name
  cert_permissions_enabled     = false
  max_session_duration_seconds = var.max_session_duration_seconds

  name_prefix = "honua-drift"
  environment = "plan"
  purpose     = each.value.purpose
  tags        = local.tags
}

data "aws_iam_policy_document" "plan_only" {
  for_each = local.roles

  statement {
    sid       = "ControlPlaneRead"
    effect    = "Allow"
    actions   = each.value.reads
    resources = ["*"]
  }

  statement {
    sid       = "StateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }

  statement {
    sid       = "StateRead"
    effect    = "Allow"
    actions   = local.state_object_actions
    resources = [each.value.state_glob]
  }

  statement {
    sid       = "StateLockOnly"
    effect    = "Allow"
    actions   = local.lock_object_actions
    resources = [each.value.lock_glob]
  }

  dynamic "statement" {
    for_each = length(each.value.object_arns) > 0 ? [1] : []
    content {
      sid       = "ManagedObjectRead"
      effect    = "Allow"
      actions   = local.demo_object_reads
      resources = each.value.object_arns
    }
  }

  dynamic "statement" {
    for_each = each.value.secrets ? [1] : []
    content {
      sid       = "ManagedSecretRefresh"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [local.demo_secret_arn]
    }
  }

  dynamic "statement" {
    for_each = each.value.secrets && length(local.demo_denied_secret_arns) > 0 ? [1] : []
    content {
      sid       = "DenyOperatorOwnedSecrets"
      effect    = "Deny"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = local.demo_denied_secret_arns
    }
  }

  # Backstop: nothing outside the list above, from this or any later policy.
  statement {
    sid    = "DenyEverythingElse"
    effect = "Deny"
    not_actions = distinct(concat(
      each.value.reads,
      ["s3:ListBucket"],
      local.state_object_actions,
      local.lock_object_actions,
      length(each.value.object_arns) > 0 ? local.demo_object_reads : [],
      each.value.secrets ? ["secretsmanager:GetSecretValue"] : [],
    ))
    resources = ["*"]
  }

  # The only writes are lock files under the role's own state prefix.
  statement {
    sid           = "DenyWritesOutsideLockFiles"
    effect        = "Deny"
    actions       = local.lock_object_actions
    not_resources = [each.value.lock_glob]
  }
}

resource "aws_iam_role_policy" "plan_only" {
  for_each = local.roles

  name   = "plan-only"
  role   = module.oidc[each.key].role_name
  policy = data.aws_iam_policy_document.plan_only[each.key].json
}
