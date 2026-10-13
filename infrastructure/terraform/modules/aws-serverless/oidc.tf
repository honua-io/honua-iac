variable "oidc_static_jwt" {
  description = "Optional static JWT issuer. The existing signing secret is managed outside Terraform and must hold at least 32 UTF-8 bytes. Lambda requires honua-server signing-secret reference support. No secret value is read or stored by Terraform."
  type = object({
    issuer                  = string
    audience                = string
    signing_key_secret_arn  = string
    signing_key_kms_key_arn = optional(string, "")
  })
  default = null

  validation {
    condition = var.oidc_static_jwt == null ? true : (
      can(regex("^https://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$", var.oidc_static_jwt.issuer)) &&
      trimspace(var.oidc_static_jwt.audience) != "" &&
      can(regex("^arn:aws[a-zA-Z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$", var.oidc_static_jwt.signing_key_secret_arn)) &&
      (var.oidc_static_jwt.signing_key_kms_key_arn == "" || can(regex("^arn:aws[a-zA-Z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.oidc_static_jwt.signing_key_kms_key_arn)))
    )
    error_message = "oidc_static_jwt requires an HTTPS issuer, nonempty audience, exact existing Secrets Manager ARN and an optional exact KMS key ARN."
  }
}

locals {
  oidc_static_environment = var.oidc_static_jwt == null ? {} : {
    Oidc__Enabled            = "true"
    Oidc__Generic__Enabled   = "true"
    Oidc__Generic__Authority = var.oidc_static_jwt.issuer
    Oidc__Generic__ClientId  = var.oidc_static_jwt.audience
  }
  oidc_static_http_only_keys = var.oidc_static_jwt == null ? [] : concat(keys(local.oidc_static_environment), ["Oidc__TokenValidation__SymmetricSigningKey"])
  oidc_signing_secret_arns   = var.oidc_static_jwt == null ? [] : [var.oidc_static_jwt.signing_key_secret_arn]
  oidc_signing_kms_arns      = var.oidc_static_jwt == null ? [] : compact([var.oidc_static_jwt.signing_key_kms_key_arn])
}

resource "terraform_data" "oidc_static_jwt" {
  count = var.oidc_static_jwt == null ? 0 : 1
  lifecycle {
    precondition {
      condition = length(setintersection(toset([for name in keys(var.additional_env) : lower(replace(name, ":", "__"))]), toset([
        "oidc__enabled", "oidc__generic__enabled", "oidc__generic__authority", "oidc__generic__clientid"
      ]))) == 0
      error_message = "Configure a static JWT issuer only through oidc_static_jwt, without competing additional_env issuer settings."
    }
  }
}
