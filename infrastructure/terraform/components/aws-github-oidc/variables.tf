###############################################################################
# Inputs for the GitHub Actions -> AWS OIDC federation (honua-iac#2164).
#
# This is the FIRST aws_iam_openid_connect_provider in this repo. It lets a
# dispatched GitHub Actions workflow assume a least-privilege role via OIDC
# (no long-lived access key), scoped by the token `sub` claim to a single repo
# (and, optionally, a single ref/environment) — modeled on the Azure federated
# identity precedent in components/cloud-demo-smoke-credentials.
###############################################################################

variable "name_prefix" {
  description = "Name prefix for resources."
  type        = string
  default     = "honua-cert"
}

variable "environment" {
  description = "Environment name (used in resource naming and tags)."
  type        = string
  default     = "cert"
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}

variable "purpose" {
  description = "Purpose tag value applied to every taggable resource."
  type        = string
  default     = "github-oidc-federation"
}

# ---------------------------------------------------------------------------
# OIDC provider. AWS no longer requires an accurate thumbprint for the GitHub
# OIDC provider (it validates the JWKS against a trusted root CA), but the
# provider still requires the field, so the long-standing GitHub Actions
# intermediate-cert thumbprint is supplied as a stable, well-known value.
# ---------------------------------------------------------------------------

variable "create_oidc_provider" {
  description = "Create the token.actions.githubusercontent.com OIDC provider. Set false if the AWS account already has one (only one provider per issuer URL is allowed per account) and pass its ARN via existing_oidc_provider_arn instead."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider to reuse when create_oidc_provider = false. Required in that case."
  type        = string
  default     = ""
}

variable "github_oidc_thumbprints" {
  description = "Certificate thumbprint(s) for token.actions.githubusercontent.com. AWS validates GitHub OIDC against a trusted root regardless, but the field is required; the default is GitHub's well-known intermediate thumbprint."
  type        = list(string)
  default     = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ---------------------------------------------------------------------------
# Trust scoping. The role trust policy authorizes ONLY tokens whose `sub`
# EXACTLY equals one of the computed subjects (StringEquals, no wildcards).
# Default: repo:<github_owner>/<github_repository>:ref:<github_oidc_ref>, i.e.
# the protected trunk branch of the honua-server repo. Set
# github_oidc_environment (or github_oidc_subjects) to pin to a GitHub
# Environment instead, e.g. repo:honua-io/honua-server:environment:cert.
# ---------------------------------------------------------------------------

variable "github_owner" {
  description = "GitHub org/owner that owns the repo allowed to assume the role."
  type        = string
  default     = "honua-io"
}

variable "github_repository" {
  description = "GitHub repository (without owner) whose workflow may assume the role. The cert workflow that drives real-AWS certification lives here."
  type        = string
  default     = "honua-server"
}

variable "github_oidc_ref" {
  description = "Git ref the default subject pins to (repo:<owner>/<repo>:ref:<ref>). Ignored when github_oidc_environment or github_oidc_subjects is set."
  type        = string
  default     = "refs/heads/trunk"

  validation {
    condition     = can(regex("^refs/(heads|tags)/[^*?]+$", var.github_oidc_ref))
    error_message = "github_oidc_ref must be an exact refs/heads/... or refs/tags/... ref with no wildcards."
  }
}

variable "github_oidc_environment" {
  description = "GitHub Environment the default subject pins to (repo:<owner>/<repo>:environment:<name>). Use it when the assuming job declares `environment:`, because such a job presents the environment subject instead of the ref subject. Empty pins to github_oidc_ref."
  type        = string
  default     = ""

  validation {
    condition     = !can(regex("[*?]", var.github_oidc_environment))
    error_message = "github_oidc_environment must not contain wildcards."
  }
}

variable "github_oidc_subjects" {
  description = "Explicit list of exact OIDC `sub` claim values allowed to assume the role (matched with StringEquals). When non-empty this overrides github_owner/github_repository/github_oidc_ref/github_oidc_environment entirely, e.g. [\"repo:honua-io/honua-server:environment:cert\"]. Wildcards are refused."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for subject in var.github_oidc_subjects : startswith(subject, "repo:") && !can(regex("[*?]", subject))])
    error_message = "github_oidc_subjects must be exact repo:<owner>/<repo>:... subjects with no * or ? wildcards (the trust policy uses StringEquals)."
  }
}

variable "oidc_audience" {
  description = "Expected OIDC audience (aud) claim. For AWS STS via the official aws-actions/configure-aws-credentials this is sts.amazonaws.com."
  type        = string
  default     = "sts.amazonaws.com"
}

variable "role_name" {
  description = "Name of the federated role. Empty keeps the historical \"<name_prefix>-<environment>-gha\" name."
  type        = string
  default     = ""

  validation {
    condition     = var.role_name == "" || can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.role_name))
    error_message = "role_name must be empty or a valid IAM role name (at most 64 characters)."
  }
}

variable "cert_permissions_enabled" {
  description = "Attach the honua-cert-* certification permission policy to the role. Set false to reuse this federation for another purpose and attach that purpose's policy to the role_name output instead (bootstrap/aws-drift-plan does this for the plan-only drift roles)."
  type        = bool
  default     = true
}

variable "max_session_duration_seconds" {
  description = "Maximum assumed-role session duration in seconds (900-43200). A short ceiling bounds a leaked cert credential."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration_seconds >= 900 && var.max_session_duration_seconds <= 43200
    error_message = "max_session_duration_seconds must be between 900 and 43200."
  }
}

# ---------------------------------------------------------------------------
# Permission scoping. The role's inline policy is scoped by Resource/Condition
# to the honua-cert-* surface the cert workflow exercises. ARNs are derived
# from the inputs below so the cert stack can pass the exact resources it owns.
# ---------------------------------------------------------------------------

variable "resource_name_prefix" {
  description = "The honua-cert-* naming prefix the cert resources use (name_prefix-environment). Batch/Lambda/log ARNs are scoped with this prefix wildcard."
  type        = string
  default     = "honua-cert-cert"
}

variable "cert_artifact_bucket_arn" {
  description = "ARN of the cert artifact S3 bucket the workflow reads/writes. Empty grants no S3 access."
  type        = string
  default     = ""
}

variable "batch_job_role_arns" {
  description = "Role ARNs the workflow may iam:PassRole, condition-locked to batch/ecs-tasks. In the cert stack this is ONLY the ECS/ALB cutover execution role (ecs:UpdateService needs it). The GP job/execution roles are intentionally NOT passed: SubmitJob against the standing pool rides the roles terraform baked in at register time, and passing them would reopen the register(role-carrying)+submit escalation. Empty grants no PassRole."
  type        = list(string)
  default     = []
}

variable "cert_alb_modify_resource_arns" {
  description = "ELBv2 listener + listener-rule ARNs the cert workflow may ModifyListener/ModifyRule to perform the weighted stable/canary cutover (the ECS/ALB certification cell). Empty grants no ELBv2 modify permission (optional-grant pattern)."
  type        = list(string)
  default     = []
}

variable "extra_invoke_function_arns" {
  description = "Additional Lambda function ARNs the cert workflow may invoke beyond the honua-cert-* prefix (e.g. a demo flip target). Empty adds none."
  type        = list(string)
  default     = []
}

variable "jobdef_lifecycle_name_prefix" {
  description = "Name prefix for EPHEMERAL per-run Batch job definitions the certification tests register/deregister/tag (honua-certrun-<runid>-*). MUST be a namespace DISJOINT from resource_name_prefix (the standing submittable pool) so this register/deregister grant can never touch a standing definition — the cert stack passes \"honua-certrun\", which shares no wildcard-matching prefix with honua-cert-cert-*. Defaults to resource_name_prefix when empty (no separation — only safe when nothing standing shares the prefix)."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Optional hosted-pilot foundation bootstrap executor role
# (honua-iac .github/workflows/hosted-pilot-bootstrap.yml). See main.tf.
# ---------------------------------------------------------------------------

variable "hosted_pilot_bootstrap_role_enabled" {
  description = "Create the OIDC role assumed by honua-iac's hosted-pilot-bootstrap.yml `bootstrap` job. Set its role_arn output as the HONUA_AWS_HOSTED_PILOT_BOOTSTRAP_ROLE_ARN repository variable."
  type        = bool
  default     = false
}

variable "hosted_pilot_bootstrap_role_name" {
  description = "Name of the hosted-pilot bootstrap executor role. Keep the -gha suffix: the local-only bootstrap users deny passing or editing *-gha roles."
  type        = string
  default     = "honua-hosted-pilot-bootstrap-gha"
}

variable "hosted_pilot_bootstrap_oidc_subjects" {
  description = "Exact `sub` values (StringEquals) allowed to assume the hosted-pilot bootstrap role. Default: the honua-iac job running in the terraform-ephemeral environment. Pair it with a trunk-only deployment-branch policy on that environment."
  type        = list(string)
  default     = ["repo:honua-io/honua-iac:environment:terraform-ephemeral"]

  validation {
    condition = length(var.hosted_pilot_bootstrap_oidc_subjects) > 0 && alltrue([
      for subject in var.hosted_pilot_bootstrap_oidc_subjects :
      startswith(subject, "repo:honua-io/honua-iac:") && !can(regex("[*?]", subject))
    ])
    error_message = "hosted_pilot_bootstrap_oidc_subjects must be exact repo:honua-io/honua-iac:... subjects with no wildcards."
  }
}

variable "hosted_pilot_bootstrap_policy_arns" {
  description = "Managed policy ARNs granting the reviewed hosted-pilot foundation executor permissions (the policy the retired static-key principal held). Required when the role is enabled. Broad AWS-managed administrator policies are refused."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.hosted_pilot_bootstrap_policy_arns :
      can(regex("^arn:[^:]+:iam::([0-9]{12}|aws):policy/.+$", arn)) &&
      !can(regex(":policy/(AdministratorAccess|PowerUserAccess|IAMFullAccess)$", arn))
    ])
    error_message = "hosted_pilot_bootstrap_policy_arns must be IAM managed policy ARNs and must not be AdministratorAccess, PowerUserAccess or IAMFullAccess."
  }
}

variable "hosted_pilot_bootstrap_permissions_boundary_arn" {
  description = "Optional permissions boundary for the hosted-pilot bootstrap role. Empty attaches none."
  type        = string
  default     = ""
}

variable "hosted_pilot_bootstrap_max_session_duration_seconds" {
  description = "Maximum session duration for the hosted-pilot bootstrap role. The workflow requests one hour, which covers its 45-minute job deadline."
  type        = number
  default     = 3600

  validation {
    condition     = var.hosted_pilot_bootstrap_max_session_duration_seconds >= 3600 && var.hosted_pilot_bootstrap_max_session_duration_seconds <= 43200
    error_message = "hosted_pilot_bootstrap_max_session_duration_seconds must be between 3600 and 43200."
  }
}
