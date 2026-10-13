variable "oidc_static_jwt" {
  description = "Optional static JWT issuer. The existing signing secret is managed outside Terraform and must hold at least 32 UTF-8 bytes. Lambda requires honua-server signing-secret reference support. No secret value is read or stored by Terraform."
  type = object({
    issuer                        = string
    audience                      = string
    signing_key_secret_arn        = string
    signing_key_kms_key_arn       = optional(string, "")
    signing_key_secret_version_id = optional(string, "")
  })
  default = null

  validation {
    condition = var.oidc_static_jwt == null ? true : (
      can(regex("^https://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$", var.oidc_static_jwt.issuer)) &&
      trimspace(var.oidc_static_jwt.audience) != "" &&
      (var.oidc_static_jwt.signing_key_secret_version_id == "" || can(regex("^[A-Za-z0-9-]{32,64}$", var.oidc_static_jwt.signing_key_secret_version_id))) &&
      can(regex("^arn:aws[a-zA-Z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$", var.oidc_static_jwt.signing_key_secret_arn)) &&
      (var.oidc_static_jwt.signing_key_kms_key_arn == "" || can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.oidc_static_jwt.signing_key_kms_key_arn)))
    )
    error_message = "oidc_static_jwt requires an HTTPS issuer, nonempty audience, exact existing Secrets Manager ARN and an optional exact KMS key ARN."
  }
}
