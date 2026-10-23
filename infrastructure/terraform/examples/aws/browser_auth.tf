# The module validates the issuer, callbacks, secret references and conflicts.
# Keep these typed defaults aligned with modules/aws-ecs/browser_auth.tf.
variable "generic_oidc" {
  description = "Optional confidential Generic OIDC browser client. Supply references to existing secrets; no secret values enter this input. Roles, tenant claims and human grants are configured separately."
  type = object({
    authority                 = string
    client_id                 = string
    admin_auth_callback_uri   = optional(string)
    scopes                    = optional(list(string), ["openid", "profile", "email"])
    client_secret_arn         = string
    client_secret_kms_key_arn = optional(string, "")
  })
  default = null
}

variable "operator_bearer" {
  description = "Optional Server-issued bearer backed by a retained Server login. Reference an independent existing signing secret containing at least 32 UTF-8 bytes."
  type = object({
    signing_key_secret_arn  = string
    signing_key_kms_key_arn = optional(string, "")
    max_lifetime_minutes    = optional(number, 30)
  })
  default = null
}
