###############################################################################
# Short-lived AWS execution identity for the governed Honua deployment lane
# (honua-iac#149).
#
# Four permission surfaces, four distinct identities:
#
#   1. BACKEND ACCESS   reads/writes exactly one Terraform state object and its
#                       lock. Created by bootstrap/aws-terraform-oidc, granted by
#                       the policy bootstrap/aws-tfstate emits. Referenced here.
#   2. INFRA DEPLOYMENT created here. Provisions the stack. Explicitly DENIED all
#                       access to the state substrate and denied any ability to
#                       mint a long-lived IAM credential.
#   3. TASK EXECUTION   pulls images and fetches secrets. Created by the module
#                       for the approved topology. Passable by the deployment
#                       role, by name prefix, only to the services that topology
#                       selects (ecs-tasks, EKS node/pod identity, or Lambda).
#   4. APP RUNTIME      the application's own identity. Created by the same module.
#
# Terraform reaches (1) through the S3 backend's own `assume_role` block. The
# process credential is already (2), so the provider must not assume a second
# role: the exact-plan receipt binds the process caller.
#
# This root creates no IAM user and no access key. There is no variable that
# makes it create one.
###############################################################################

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  name = "${var.name_prefix}-${var.environment}"

  tags = merge({
    ManagedBy                 = "terraform"
    Purpose                   = "honua-governed-execution-identity"
    Environment               = var.environment
    HonuaTopologyCompute      = var.topology.compute
    HonuaTopologyRedis        = var.topology.redis ? "true" : "false"
    HonuaTopologyCustomDomain = var.topology.custom_domain ? "true" : "false"
    HonuaTopologyWaf          = var.topology.waf ? "true" : "false"
    HonuaTopologyGpBatch      = var.topology.gp_batch ? "true" : "false"
  }, var.tags)

  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  use_oidc = var.trust_mode == "oidc" || var.trust_mode == "both"
  use_sso  = var.trust_mode == "sso" || var.trust_mode == "both"

  oidc_hostpath = trimprefix(var.oidc_provider_url, "https://")

  # These ARNs are deterministic from the inputs. Keeping them independent of
  # the resources lets the role preconditions and policy document refer to the
  # identities they protect without creating a dependency cycle.
  deployment_role_arn            = "arn:${local.partition}:iam::${local.account_id}:role/${local.name}-deploy"
  deployment_policy_arn          = "arn:${local.partition}:iam::${local.account_id}:policy/${local.name}-deploy"
  deployment_workload_policy_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${local.name}-deploy-workload"

  # Deterministic so the deployment policy can require this boundary without a
  # cycle through the policy resource.
  workload_boundary_name = "${local.name}-workload-boundary"
  workload_boundary_arn  = "arn:${local.partition}:iam::${local.account_id}:policy/${local.workload_boundary_name}"

  # One file per module and per optional feature. The names are literals so
  # file() is known at plan time. Schemas match, so the values form one map.
  manifest_names = [
    "iam-workload",
    "aws-ecs",
    "aws-eks",
    "aws-serverless",
    "redis",
    "custom-domain",
    "waf",
    "gp-batch",
  ]

  manifests = {
    for name in local.manifest_names :
    name => jsondecode(file("${path.module}/manifests/${name}.json"))
  }

  topology_compute_manifest = {
    ecs    = "aws-ecs"
    eks    = "aws-eks"
    lambda = "aws-serverless"
  }

  # iam-workload is always selected. There is no full-grant default: a feature
  # that was not approved contributes no actions, no service-linked role, and
  # no attachable AWS managed policy.
  topology_manifest_ids = concat(
    ["iam-workload", local.topology_compute_manifest[var.topology.compute]],
    var.topology.redis ? ["redis"] : [],
    var.topology.custom_domain ? ["custom-domain"] : [],
    var.topology.waf ? ["waf"] : [],
    var.topology.gp_batch ? ["gp-batch"] : [],
  )

  selected_manifests = [for id in local.topology_manifest_ids : local.manifests[id]]

  region_actions = sort(distinct(flatten([
    for manifest in local.selected_manifests : manifest.region_actions
  ])))
  global_actions = sort(distinct(flatten([
    for manifest in local.selected_manifests : manifest.global_actions
  ])))
  pass_role_services = sort(distinct(flatten([
    for manifest in local.selected_manifests : manifest.pass_role_services
  ])))
  service_linked_roles = sort(distinct(flatten([
    for manifest in local.selected_manifests : manifest.service_linked_roles
  ])))
  attachable_policy_suffixes = sort(distinct(flatten([
    for manifest in local.selected_manifests : manifest.attachable_policies
  ])))

  # Shared IAM allows. Conditions (name prefix, boundary, service list) stay in
  # this file so the policy gate can still see them as literal statements.
  iam_statement_actions = {
    for statement in local.manifests["iam-workload"].iam_statements :
    statement.sid => statement.actions
    if length(statement.actions) > 0
  }

  # Instance profiles and the EKS OIDC provider are name-prefix scoped. The
  # placeholder statement (sid None, no actions) is ignored.
  extra_iam_statements = merge([
    for manifest in local.selected_manifests : {
      for statement in manifest.iam_statements :
      statement.sid => statement
      if statement.resource_kind != null && length(statement.actions) > 0
    }
  ]...)

  extra_iam_resources = {
    "instance-profile"  = "arn:${local.partition}:iam::${local.account_id}:instance-profile/${var.name_prefix}*"
    "eks-oidc-provider" = "arn:${local.partition}:iam::${local.account_id}:oidc-provider/oidc.eks.${var.aws_region}.amazonaws.com/id/*"
  }

  manifest_allow_actions = sort(distinct(concat(
    local.region_actions,
    local.global_actions,
    flatten(values(local.iam_statement_actions)),
    flatten([for statement in values(local.extra_iam_statements) : statement.actions]),
  )))

  # AWS managed policies the selected modules attach, plus policies this root's
  # name prefix owns. AdministratorAccess is not in any manifest.
  attachable_policy_arns = concat(
    [for suffix in local.attachable_policy_suffixes : "arn:${local.partition}:iam::aws:policy/${suffix}"],
    ["arn:${local.partition}:iam::${local.account_id}:policy/${var.name_prefix}*"],
  )

  passable_role_arns = distinct(compact([
    "arn:${local.partition}:iam::${local.account_id}:role/${var.task_execution_role_name_prefix}*",
    "arn:${local.partition}:iam::${local.account_id}:role/${var.app_runtime_role_name_prefix}*",
  ]))

  # Roles the deployment identity must never be able to pass to a service: doing
  # so would let a task run as the deployer or as the backend reader.
  unpassable_role_arns = distinct(compact([
    local.deployment_role_arn,
    var.backend_access_role_arn,
  ]))

  state_substrate_arns = distinct(compact(concat([
    var.state_bucket_arn,
    "${var.state_bucket_arn}/*",
  ], var.state_lock_table_arn == "" ? [] : [var.state_lock_table_arn])))

  execution_identity_contract = {
    schema_version = "v1"
    kind           = "honua.iac.execution-identity"
    account = {
      account_id = local.account_id
      partition  = local.partition
      region     = var.aws_region
    }
    federation = {
      mode                 = var.trust_mode
      issuer               = local.use_oidc ? var.oidc_provider_url : null
      audience             = local.use_oidc ? var.oidc_audience : null
      subjects             = local.use_oidc ? var.oidc_subjects : []
      trusted_principals   = local.use_sso ? var.trusted_principal_arns : []
      max_session_duration = var.max_session_duration
      credential_kind      = "short-lived-sts-only"
    }
    roles = {
      backend_access = {
        purpose    = "terraform-state-and-lock-only"
        role_arn   = var.backend_access_role_arn != "" ? var.backend_access_role_arn : null
        policy_arn = var.backend_access_policy_arn != "" ? var.backend_access_policy_arn : null
        created_by = "bootstrap/aws-terraform-oidc"
      }
      infra_deployment = {
        purpose    = "provision-stack-resources"
        role_arn   = local.deployment_role_arn
        policy_arn = local.deployment_policy_arn
        created_by = "bootstrap/aws-exec-identity"
      }
      task_execution = {
        purpose            = "ecs-image-pull-and-secret-fetch"
        role_arn           = var.task_execution_role_arn != "" ? var.task_execution_role_arn : null
        role_name_prefix   = var.task_execution_role_name_prefix
        created_by         = "modules/aws-ecs"
        passable_by_deploy = true
      }
      app_runtime = {
        purpose            = "application-workload-identity"
        role_arn           = var.app_runtime_role_arn != "" ? var.app_runtime_role_arn : null
        role_name_prefix   = var.app_runtime_role_name_prefix
        created_by         = "modules/aws-ecs"
        passable_by_deploy = true
      }
      workload_permissions_boundary = {
        purpose    = "ceiling-for-roles-this-identity-creates"
        policy_arn = local.workload_boundary_arn
        created_by = "bootstrap/aws-exec-identity"
      }
    }
    separation = {
      backend_access_denied_to_deployment = true
      long_lived_credentials_denied       = true
      deployment_role_not_passable        = true
      workload_boundary_required          = true
      iam_user_created                    = false
      access_key_created                  = false
    }
    evidence_scope = "non-secret-identity-references"
  }
}

# ---------------------------------------------------------------------------
# Trust policy. Web identity, already-federated principals, or both. Never a
# long-lived IAM user.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deployment_trust" {
  dynamic "statement" {
    for_each = local.use_oidc ? [1] : []

    content {
      sid     = "WebIdentityFederation"
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]

      principals {
        type        = "Federated"
        identifiers = [var.oidc_provider_arn]
      }

      condition {
        test     = "StringEquals"
        variable = "${local.oidc_hostpath}:aud"
        values   = [var.oidc_audience]
      }

      condition {
        test     = "StringLike"
        variable = "${local.oidc_hostpath}:sub"
        values   = var.oidc_subjects
      }
    }
  }

  dynamic "statement" {
    for_each = local.use_sso ? [1] : []

    content {
      sid     = "FederatedPrincipalAssumeRole"
      effect  = "Allow"
      actions = ["sts:AssumeRole", "sts:TagSession"]

      principals {
        type        = "AWS"
        identifiers = var.trusted_principal_arns
      }
    }
  }
}

resource "aws_iam_role" "deployment" {
  name                 = "${local.name}-deploy"
  description          = "Honua infrastructure deployment role. Short-lived STS sessions only."
  assume_role_policy   = data.aws_iam_policy_document.deployment_trust.json
  max_session_duration = var.max_session_duration
  tags                 = local.tags

  lifecycle {
    precondition {
      condition = !local.use_oidc || (
        trimspace(var.oidc_provider_arn) != "" &&
        trimspace(var.oidc_provider_url) != "" &&
        length(var.oidc_subjects) > 0
      )
      error_message = "trust_mode includes oidc, so oidc_provider_arn, oidc_provider_url and at least one oidc_subject are required."
    }

    precondition {
      condition     = !local.use_sso || length(var.trusted_principal_arns) > 0
      error_message = "trust_mode includes sso, so at least one trusted principal ARN is required."
    }

    precondition {
      condition = alltrue([
        for arn in compact([
          var.backend_access_role_arn,
          var.task_execution_role_arn,
          var.app_runtime_role_arn,
        ]) : arn != local.deployment_role_arn
      ])
      error_message = "The deployment role must be distinct from the backend, task execution, and application runtime roles."
    }

    precondition {
      condition = length(compact([
        var.backend_access_role_arn,
        var.task_execution_role_arn,
        var.app_runtime_role_arn,
        ])) == length(distinct(compact([
          var.backend_access_role_arn,
          var.task_execution_role_arn,
          var.app_runtime_role_arn,
      ])))
      error_message = "The backend, task execution, and application runtime roles must be three different roles."
    }
  }
}

# ---------------------------------------------------------------------------
# Deployment permissions. Region-scoped allows, plus the three denials that keep
# this role inside its lane: no state substrate, no long-lived credentials, no
# passing the privileged roles.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deployment" {
  #checkov:skip=CKV_AWS_356: Several provisioning APIs (ec2/elb/ecs describe, tag) have no resource-level scoping; the region condition plus explicit denials bound them.
  #checkov:skip=CKV_AWS_110: Provisioning inherently needs create/delete across the stack's services.
  #checkov:skip=CKV_AWS_111: Write access is required to provision; PassRole is separately constrained.
  #checkov:skip=CKV_AWS_107: Secret creation is required to provision the stack's managed secrets.
  #checkov:skip=CKV_AWS_108: Networking and logging actions are required to provision the stack.
  #checkov:skip=CKV_AWS_109: Role management is required for the task roles; user/key management is explicitly denied.
  statement {
    sid       = "ProvisionStackResources"
    effect    = "Allow"
    actions   = local.region_actions
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # Route 53 uses a global endpoint, so aws:RequestedRegion cannot match the
  # cell region outside us-east-1. The statement exists only when the approved
  # topology includes a custom domain.
  dynamic "statement" {
    for_each = length(local.global_actions) > 0 ? [1] : []

    content {
      sid       = "ManageHostedZoneRecords"
      effect    = "Allow"
      actions   = local.global_actions
      resources = ["*"]
    }
  }
}

# Role administration is its own managed policy. The deployment document is
# already near the 6,144 non-whitespace character quota; these statements
# pushed a single policy over it. Denies stay with the grants they constrain.
data "aws_iam_policy_document" "deployment_workload" {
  # Creating or editing a workload role requires this root's boundary. The
  # condition key is absent on service-linked roles, so those are a separate
  # statement below.
  statement {
    sid     = "CreateBoundedWorkloadRoles"
    effect  = "Allow"
    actions = local.iam_statement_actions["CreateBoundedWorkloadRoles"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}*",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.workload_boundary_arn]
    }
  }

  statement {
    sid       = "AttachBoundedWorkloadPolicies"
    effect    = "Allow"
    actions   = local.iam_statement_actions["AttachBoundedWorkloadPolicies"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.workload_boundary_arn]
    }

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values   = local.attachable_policy_arns
    }
  }

  statement {
    sid     = "ManageWorkloadRoles"
    effect  = "Allow"
    actions = local.iam_statement_actions["ManageWorkloadRoles"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}*",
      "arn:${local.partition}:iam::${local.account_id}:policy/${var.name_prefix}*",
    ]
  }

  statement {
    sid       = "CreateServiceLinkedRoles"
    effect    = "Allow"
    actions   = local.iam_statement_actions["CreateServiceLinkedRoles"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = local.service_linked_roles
    }
  }

  statement {
    sid       = "PassWorkloadRoles"
    effect    = "Allow"
    actions   = local.iam_statement_actions["PassWorkloadRoles"]
    resources = local.passable_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = local.pass_role_services
    }
  }

  dynamic "statement" {
    for_each = local.extra_iam_statements

    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = statement.value.actions
      resources = [local.extra_iam_resources[statement.value.resource_kind]]
    }
  }

  # --- separation denials --------------------------------------------------

  # The state substrate belongs to the BACKEND role. A deployment session that
  # could write state directly could rewrite lineage under an approved plan.
  statement {
    sid    = "DenyStateSubstrateAccess"
    effect = "Deny"
    actions = [
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]
    resources = local.state_substrate_arns
  }

  # Nothing on the certified path may create a credential that outlives the
  # session that created it.
  statement {
    sid    = "DenyLongLivedCredentials"
    effect = "Deny"
    actions = [
      "iam:AttachUserPolicy",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:CreateServiceSpecificCredential",
      "iam:CreateUser",
      "iam:PutUserPolicy",
      "iam:ResetServiceSpecificCredential",
      "iam:UpdateAccessKey",
      "iam:UpdateLoginProfile",
      "iam:UploadSSHPublicKey",
    ]
    resources = ["*"]
  }

  # No privilege loop: the deployment role cannot hand its own identity, or the
  # backend reader's, to a running task.
  statement {
    sid    = "DenyPassingPrivilegedRoles"
    effect = "Deny"
    actions = [
      "iam:PassRole",
    ]
    resources = local.unpassable_role_arns
  }

  # Keep the deployment and backend identities outside the workload-management
  # wildcard. Explicit denies preserve the separation even when names share a
  # common prefix.
  statement {
    sid    = "DenyDeploymentIdentityMutation"
    effect = "Deny"
    actions = [
      "iam:AttachRolePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
    ]
    resources = compact([
      local.deployment_role_arn,
      local.deployment_policy_arn,
      local.deployment_workload_policy_arn,
      local.workload_boundary_arn,
      var.backend_access_role_arn,
      var.backend_access_policy_arn,
    ])
  }

  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

# Ceiling for every role this identity creates. The role's own policy still
# scopes the grant. This document removes IAM, role chaining, the state
# substrate, and the deployer/backend identities from that ceiling.
data "aws_iam_policy_document" "workload_boundary" {
  #checkov:skip=CKV_AWS_107: A permissions boundary is a ceiling, not a grant; the roles' own policies scope access.
  #checkov:skip=CKV_AWS_108: A permissions boundary is a ceiling, not a grant; the roles' own policies scope access.
  #checkov:skip=CKV_AWS_109: The ceiling is NotAction iam:*; checkov reads NotAction as a grant of everything.
  #checkov:skip=CKV_AWS_110: The ceiling is NotAction iam:*; checkov reads NotAction as a grant of everything.
  #checkov:skip=CKV_AWS_111: A permissions boundary is a ceiling, not a grant; the roles' own policies scope access.
  #checkov:skip=CKV_AWS_356: A permissions boundary is a ceiling, not a grant; the roles' own policies scope resources.

  statement {
    sid    = "WorkloadServiceCeiling"
    effect = "Allow"
    not_actions = [
      "account:*",
      "iam:*",
      "organizations:*",
      "sts:AssumeRole",
      "sts:AssumeRoleWithSAML",
      "sts:AssumeRoleWithWebIdentity",
      "sts:GetFederationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyStateSubstrate"
    effect = "Deny"
    actions = [
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]
    resources = local.state_substrate_arns
  }

  statement {
    sid    = "DenyPrivilegedIdentities"
    effect = "Deny"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DeleteRole",
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PassRole",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
      "iam:UpdateAssumeRolePolicy",
      "sts:AssumeRole",
      "sts:AssumeRoleWithSAML",
      "sts:AssumeRoleWithWebIdentity",
      "sts:GetFederationToken",
    ]
    resources = local.unpassable_role_arns
  }
}

locals {
  deployment_policy_size          = length(replace(replace(replace(data.aws_iam_policy_document.deployment.json, " ", ""), "\n", ""), "\t", ""))
  deployment_workload_policy_size = length(replace(replace(replace(data.aws_iam_policy_document.deployment_workload.json, " ", ""), "\n", ""), "\t", ""))

  rendered_allow_actions = sort(distinct(concat(
    flatten([
      for statement in jsondecode(data.aws_iam_policy_document.deployment.json).Statement :
      statement.Effect == "Allow" ? try(tolist(statement.Action), [statement.Action]) : []
    ]),
    flatten([
      for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement :
      statement.Effect == "Allow" ? try(tolist(statement.Action), [statement.Action]) : []
    ]),
  )))

  deploy_actions_by_service = {
    for service in distinct([for action in local.manifest_allow_actions : split(":", action)[0]]) :
    service => sort([
      for action in local.manifest_allow_actions : action
      if split(":", action)[0] == service
    ])
  }

  # What a customer-facing agent can say this role cannot do. Feature lines
  # appear only for flags that are off, so the sentence matches the policy.
  deploy_identity_cannot = concat(
    [
      "Read or write the Terraform state bucket or lock table.",
      "Create an IAM user, access key, login profile, or service-specific credential.",
      "Pass the deployment role or the backend access role to a service.",
      "Mutate the deployment role, its policies, or the workload permissions boundary.",
      "Delete a permissions boundary.",
      "Call an action that is not listed in actions_by_service. This role is not an IAM administrator, and the agent that assumes it cannot widen it.",
    ],
    var.topology.redis ? [] : ["Manage ElastiCache. redis is not part of the approved topology."],
    var.topology.custom_domain ? [] : ["Manage ACM certificates or Route 53 records. custom_domain is not part of the approved topology."],
    var.topology.waf ? [] : ["Manage WAFv2 web ACLs. waf is not part of the approved topology."],
    var.topology.gp_batch ? [] : ["Manage AWS Batch, including custom-code batch resources. gp_batch is not part of the approved topology."],
    var.topology.compute == "ecs" ? [] : ["Provision an ECS cluster or service. compute is ${var.topology.compute}."],
    var.topology.compute == "eks" ? [] : ["Provision EKS. compute is ${var.topology.compute}."],
    var.topology.compute == "lambda" ? [] : ["Provision Lambda. compute is ${var.topology.compute}."],
  )

  deploy_identity_contract = {
    schema_version = "v1"
    kind           = "honua.iac.deploy-identity"
    topology = {
      compute       = var.topology.compute
      redis         = var.topology.redis
      custom_domain = var.topology.custom_domain
      waf           = var.topology.waf
      gp_batch      = var.topology.gp_batch
    }
    role_arn           = local.deployment_role_arn
    role_name          = "${local.name}-deploy"
    assume             = "Assume ${local.deployment_role_arn} with a short-lived STS session (sts:AssumeRole or sts:AssumeRoleWithWebIdentity). The agent does not need IAM-admin and cannot grant itself actions outside this contract."
    actions_by_service = local.deploy_actions_by_service
    cannot             = local.deploy_identity_cannot
    batch_scope        = var.topology.gp_batch ? "gp_batch grants every Batch action modules/aws-serverless uses, including custom-code batch resources." : null
    policy_sizes = {
      deployment             = local.deployment_policy_size
      deployment_workload    = local.deployment_workload_policy_size
      managed_policy_limit   = 6144
      inline_aggregate_limit = 10240
      inline_policies        = 0
    }
    manifests      = local.topology_manifest_ids
    evidence_scope = "non-secret-identity-references"
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = local.workload_boundary_name
  description = "Permissions boundary required on every role created by the certified deployment role."
  policy      = data.aws_iam_policy_document.workload_boundary.json
  tags        = local.tags
}

resource "aws_iam_policy" "deployment" {
  name        = "${local.name}-deploy"
  description = "Least-privilege Honua infrastructure deployment permissions for the approved topology, with state-substrate and long-lived-credential denials."
  policy      = data.aws_iam_policy_document.deployment.json
  tags        = local.tags

  lifecycle {
    precondition {
      condition     = local.deployment_policy_size <= 6144
      error_message = "Deployment policy is ${local.deployment_policy_size} non-whitespace characters. The managed-policy quota is 6144. Split the document before applying."
    }
  }
}

resource "aws_iam_role_policy_attachment" "deployment" {
  role       = aws_iam_role.deployment.name
  policy_arn = aws_iam_policy.deployment.arn
}

resource "aws_iam_policy" "deployment_workload" {
  name        = "${local.name}-deploy-workload"
  description = "Role-administration grants for the certified deployment role, split so each managed policy stays inside the size quota. These are managed policies: the 10240-character inline aggregate does not apply, and this root attaches no inline policy."
  policy      = data.aws_iam_policy_document.deployment_workload.json
  tags        = local.tags

  lifecycle {
    precondition {
      condition     = local.deployment_workload_policy_size <= 6144
      error_message = "Deployment workload policy is ${local.deployment_workload_policy_size} non-whitespace characters. The managed-policy quota is 6144."
    }

    # A mocked policy document (approval-mac tests) is an empty statement list.
    # A real document is checked against the selected manifests.
    precondition {
      condition = (
        length(local.rendered_allow_actions) == 0
        || toset(local.rendered_allow_actions) == toset(local.manifest_allow_actions)
      )
      error_message = "Rendered deployment allows drifted from the selected topology manifests."
    }

    precondition {
      condition     = length(local.pass_role_services) > 0 && length(local.service_linked_roles) > 0 && length(local.region_actions) > 0
      error_message = "The approved topology produced an empty PassRole, service-linked role, or regional action list."
    }

    precondition {
      condition = !anytrue([
        for arn in local.attachable_policy_arns : strcontains(arn, "AdministratorAccess")
      ])
      error_message = "The deployment role must not be able to attach AdministratorAccess."
    }
  }
}

resource "aws_iam_role_policy_attachment" "deployment_workload" {
  role       = aws_iam_role.deployment.name
  policy_arn = aws_iam_policy.deployment_workload.arn
}
