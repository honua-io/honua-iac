# Real Generic OIDC browser sign-in and the Server-issued session bearer are separate opt-ins.
variable "generic_oidc" {
  description = "Optional confidential Generic OIDC browser client. Secret values remain external; ECS injects the referenced client secret. Does not configure roles, tenant claims, entitlement, routing or human grants."
  type = object({
    authority                 = string
    client_id                 = string
    admin_auth_callback_uri   = optional(string)
    scopes                    = optional(list(string), ["openid", "profile", "email"])
    client_secret_arn         = string
    client_secret_kms_key_arn = optional(string, "")
  })
  default = null
  validation {
    condition = var.generic_oidc == null ? true : (
      can(regex("^https://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$", var.generic_oidc.authority)) &&
      can(regex("^[^[:space:]]+$", var.generic_oidc.client_id)) &&
      (var.generic_oidc.admin_auth_callback_uri == null ? true : can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?/admin/auth/callback$", var.generic_oidc.admin_auth_callback_uri))) &&
      contains(var.generic_oidc.scopes, "openid") && length(distinct(var.generic_oidc.scopes)) == length(var.generic_oidc.scopes) &&
      alltrue([for scope in var.generic_oidc.scopes : can(regex("^[^[:space:]]+$", scope))]) &&
      can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.generic_oidc.client_secret_arn)) &&
      (var.generic_oidc.client_secret_kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.generic_oidc.client_secret_kms_key_arn)))
    )
    error_message = "generic_oidc requires HTTPS authority, nonempty client ID, unique nonempty scopes including openid, an exact complete Secrets Manager ARN and optional exact KMS key ARN."
  }
}
variable "operator_bearer" {
  description = "Optional Server-issued operator bearer backed by a real retained Server login. External signing secret must contain at least 32 UTF-8 bytes. No synthetic identity or additional permission is granted."
  type = object({
    signing_key_secret_arn  = string
    signing_key_kms_key_arn = optional(string, "")
    max_lifetime_minutes    = optional(number, 30)
  })
  default = null
  validation {
    condition = var.operator_bearer == null ? true : (
      can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.operator_bearer.signing_key_secret_arn)) &&
      (var.operator_bearer.signing_key_kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.operator_bearer.signing_key_kms_key_arn))) &&
      var.operator_bearer.max_lifetime_minutes >= 1 && var.operator_bearer.max_lifetime_minutes <= 720 && floor(var.operator_bearer.max_lifetime_minutes) == var.operator_bearer.max_lifetime_minutes
    )
    error_message = "operator_bearer requires an exact complete Secrets Manager ARN, optional exact KMS key ARN, and integer lifetime from 1 through 720 minutes."
  }
}
locals {
  browser_auth_environment = merge(var.generic_oidc == null ? {} : merge({
    Oidc__Enabled            = "true"
    Oidc__Generic__Enabled   = "true"
    Oidc__Generic__Authority = var.generic_oidc.authority
    Oidc__Generic__ClientId  = var.generic_oidc.client_id
    }, { for i, scope in var.generic_oidc.scopes : "Oidc__Generic__Scopes__${i}" => scope }, var.generic_oidc.admin_auth_callback_uri == null ? {} : { Oidc__AdminAuthCallbackUri = var.generic_oidc.admin_auth_callback_uri }), var.operator_bearer == null ? {} : {
    Authentication__OperatorBearer__Enabled            = "true"
    Authentication__OperatorBearer__MaxLifetimeMinutes = tostring(var.operator_bearer.max_lifetime_minutes)
  })
  browser_auth_secrets  = concat(var.generic_oidc == null ? [] : [{ name = "Oidc__Generic__ClientSecret", valueFrom = var.generic_oidc.client_secret_arn }], var.operator_bearer == null ? [] : [{ name = "Authentication__OperatorBearer__SigningKey", valueFrom = var.operator_bearer.signing_key_secret_arn }])
  browser_auth_kms_arns = distinct(compact([var.generic_oidc == null ? "" : var.generic_oidc.client_secret_kms_key_arn, var.operator_bearer == null ? "" : var.operator_bearer.signing_key_kms_key_arn]))
  browser_auth_kms_bindings = distinct(concat(
    var.generic_oidc == null ? [] : var.generic_oidc.client_secret_kms_key_arn == "" ? [] : [{
      key_arn = var.generic_oidc.client_secret_kms_key_arn
      region  = try(split(":", var.generic_oidc.client_secret_arn)[3], "")
    }],
    var.operator_bearer == null ? [] : var.operator_bearer.signing_key_kms_key_arn == "" ? [] : [{
      key_arn = var.operator_bearer.signing_key_kms_key_arn
      region  = try(split(":", var.operator_bearer.signing_key_secret_arn)[3], "")
    }]
  ))
  browser_auth_public_origins = [for environment in concat(
    [local.primary_container_environment], local.canary_enabled ? [local.canary_container_environment] : []) : [
    for entry in environment : entry.value
    if contains(["public__baseurl", "public_base_url"], lower(replace(entry.name, ":", "__")))
  ]]
  # Parse the authority separately: a non-separator regex also accepts invalid
  # ports and malformed IPv6. DNS labels use their ASCII/punycode form.
  browser_auth_origin_pattern = "^https?://(?P<host>\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\\.?)(?::(?P<port>[0-9]+))?(?:/[^?#[:space:]]*)?$"
  browser_auth_origin_authorities = [for origins in local.browser_auth_public_origins : [
    for origin in origins : try(regex(local.browser_auth_origin_pattern, origin), null)
  ]]
}
resource "terraform_data" "browser_auth" {
  lifecycle {
    precondition {
      condition     = alltrue([for binding in local.browser_auth_kms_bindings : try(split(":", binding.key_arn)[3] == binding.region, false)])
      error_message = "Each browser authentication CMK must be in the same region as its paired Secrets Manager secret."
    }
    precondition {
      condition = var.generic_oidc == null ? true : var.generic_oidc.admin_auth_callback_uri != null ? true : alltrue([
        for authorities in local.browser_auth_origin_authorities : length(authorities) == 1 && alltrue([
          for authority in authorities : authority == null ? false : (
            try(tonumber(coalesce(authority.port, "443")) <= 65535, false) &&
            (startswith(authority.host, "[") ? can(cidrhost("${trimprefix(trimsuffix(authority.host, "]"), "[")}/128", 0)) : length(authority.host) <= 253)
          )
        ])
      ])
      error_message = "generic_oidc without admin_auth_callback_uri requires one valid Public:BaseUrl on every enabled task. Set public_base_url, an HTTPS custom domain, or a single Public__BaseUrl/PUBLIC_BASE_URL environment setting."
    }
    precondition {
      condition     = var.generic_oidc == null || var.operator_bearer == null ? true : var.generic_oidc.client_secret_arn != var.operator_bearer.signing_key_secret_arn
      error_message = "Generic OIDC client and operator bearer signing secrets must be independent secret ARNs."
    }
    precondition {
      condition     = var.generic_oidc == null || var.oidc_static_jwt == null
      error_message = "generic_oidc and oidc_static_jwt configure different issuer contracts and cannot be combined."
    }
    precondition {
      condition = alltrue([for name in keys(merge(var.additional_env, var.canary_additional_env)) :
        !(var.generic_oidc != null && (startswith(lower(replace(name, ":", "__")), "oidc__generic__") || lower(replace(name, ":", "__")) == "oidc__enabled" || lower(replace(name, ":", "__")) == "oidc__adminauthcallbackuri")) &&
        !(var.operator_bearer != null && startswith(lower(replace(name, ":", "__")), "authentication__operatorbearer__"))
      ])
      error_message = "Typed browser authentication cannot be overridden by primary or canary additional_env settings."
    }
  }
}
