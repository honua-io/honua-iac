# Workload identity for the Honua server pods and the GP Kubernetes Job pods.
#
# Two IAM roles, both named under local.name (the release account's guardrail
# only admits roles in the cell's own name prefix):
#   * server — the chart's server service account; resolves the
#     aws:secretsmanager: references in honua_server_environment.
#   * gp-job — the service account GP Jobs run as
#     (ControlPlane:Kubernetes:DefaultServiceAccount); the job process composes
#     the same server DI, so it reads the same secrets, plus the GP data bucket.
#
# pod_identity (default): EKS Pod Identity associations, made through the EKS
# API — no IAM OIDC provider, no service-account annotation. irsa: the cluster's
# OIDC provider (created by the EKS module) trusted per service account; the
# chart must annotate the service accounts with *_service_account_annotations.
#
# Neither path creates Kubernetes objects: the chart owns the service accounts
# (and the Job RBAC); an association may name a service account before it exists.

locals {
  gp_job_namespace = var.gp_job_namespace != "" ? var.gp_job_namespace : var.kubernetes_namespace

  workload_service_accounts = {
    server = {
      role_name       = "${local.name}-server"
      namespace       = var.kubernetes_namespace
      service_account = var.server_service_account_name
    }
    gp-job = {
      role_name       = "${local.name}-gp-job"
      namespace       = local.gp_job_namespace
      service_account = var.gp_job_service_account_name
    }
  }

  # Every secret the server process (and therefore a GP job, which composes the
  # same DI) resolves. Operator-owned key-ring and audit-key secrets are granted
  # only when they are in play, so a Redis-off cell takes no dependency on the
  # key-ring certificate.
  operation_key_ring_secret_arns = var.redis_enabled && var.operation_key_ring_certificate_secret_arn != "" ? [var.operation_key_ring_certificate_secret_arn] : []
  audit_chain_key_secret_arns    = var.audit_chain_key_secret_arn != "" ? [var.audit_chain_key_secret_arn] : []

  workload_secret_arns = concat(
    [
      aws_secretsmanager_secret.db_connection.arn,
      aws_secretsmanager_secret.admin_password.arn,
      aws_secretsmanager_secret.master_key.arn,
    ],
    aws_secretsmanager_secret.redis_connection[*].arn,
    local.operation_key_ring_secret_arns,
    local.audit_chain_key_secret_arns,
  )

  workload_kms_key_arns = distinct(concat(
    var.secrets_kms_key_arn != "" ? [var.secrets_kms_key_arn] : [],
    var.redis_enabled && var.operation_key_ring_certificate_secret_kms_key_arn != "" ? [var.operation_key_ring_certificate_secret_kms_key_arn] : [],
    var.audit_chain_key_secret_arn != "" && var.audit_chain_key_secret_kms_key_arn != "" ? [var.audit_chain_key_secret_kms_key_arn] : [],
  ))

  pod_identity_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EksPodIdentity"
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })

  irsa_trust_policies = {
    for key, workload in local.workload_service_accounts : key => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "EksIrsa"
        Effect    = "Allow"
        Principal = { Federated = module.eks.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:${workload.namespace}:${workload.service_account}"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }]
    })
  }

  workload_service_account_annotations = {
    for key, workload in local.workload_service_accounts : key => (
      local.irsa_enabled ? { "eks.amazonaws.com/role-arn" = aws_iam_role.workload[key].arn } : {}
    )
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

resource "aws_iam_role" "workload" {
  for_each = local.workload_service_accounts

  name                 = each.value.role_name
  description          = "Honua ${each.key} pods on ${module.eks.cluster_name} (${each.value.namespace}/${each.value.service_account})"
  assume_role_policy   = local.irsa_enabled ? local.irsa_trust_policies[each.key] : local.pod_identity_trust_policy
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.tags
}

resource "aws_iam_role_policy" "workload_secrets" {
  for_each = local.workload_service_accounts

  name = "${each.value.role_name}-secrets"
  role = aws_iam_role.workload[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Sid      = "ReadHonuaRuntimeSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = local.workload_secret_arns
      }], length(local.workload_kms_key_arns) > 0 ? [{
      Sid      = "DecryptHonuaRuntimeSecrets"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = local.workload_kms_key_arns
      Condition = {
        StringLike = { "kms:ViaService" = "secretsmanager.*.amazonaws.com" }
      }
    }] : [])
  })
}

# Gated on the plan-known flag, not on the ARN, because callers pass a bucket ARN
# computed at apply time (same contract as aws-serverless gp_batch_data_bucket_*).
resource "aws_iam_role_policy" "workload_data_bucket" {
  for_each = var.gp_job_data_bucket_enabled ? local.workload_service_accounts : {}

  name = "${each.value.role_name}-gp-data"
  role = aws_iam_role.workload[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${var.gp_job_data_bucket_arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [var.gp_job_data_bucket_arn]
      }
    ]
  })

  lifecycle {
    precondition {
      condition     = can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.gp_job_data_bucket_arn))
      error_message = "gp_job_data_bucket_enabled requires gp_job_data_bucket_arn to be an S3 bucket ARN (arn:aws:s3:::<bucket>)."
    }
  }
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each = local.pod_identity_enabled ? local.workload_service_accounts : {}

  cluster_name    = module.eks.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.workload[each.key].arn
  tags            = local.tags

  # The agent add-on must be running before a pod can exchange its token.
  depends_on = [module.eks]
}
