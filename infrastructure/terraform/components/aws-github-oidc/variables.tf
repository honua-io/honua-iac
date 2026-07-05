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
# matches these patterns. Default scopes to the cert workflow on the
# honua-server repo. Tighten to a single ref or a GitHub Environment for the
# narrowest blast radius (e.g. repo:honua-io/honua-server:environment:cert).
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

variable "github_oidc_subjects" {
  description = "Explicit list of OIDC `sub` claim patterns allowed to assume the role. When non-empty this overrides github_owner/github_repository scoping entirely. Use this to pin to a specific ref or GitHub Environment, e.g. [\"repo:honua-io/honua-server:environment:cert\"]."
  type        = list(string)
  default     = []
}

variable "oidc_audience" {
  description = "Expected OIDC audience (aud) claim. For AWS STS via the official aws-actions/configure-aws-credentials this is sts.amazonaws.com."
  type        = string
  default     = "sts.amazonaws.com"
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
  description = "Role ARNs the workflow may iam:PassRole when submitting Batch jobs (the GP job + execution roles). Empty grants no PassRole."
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
  description = "Name prefix for EPHEMERAL per-run Batch job definitions the certification tests register/deregister/tag (honua-cert-<runid>-*). Defaults to resource_name_prefix; the cert stack passes the shorter run prefix (honua-cert) because per-run names omit the environment segment."
  type        = string
  default     = ""
}
