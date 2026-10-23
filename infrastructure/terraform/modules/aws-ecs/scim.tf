# This carrier does not enroll users or assert that a selected Server build supports SCIM.
variable "scim_provisioning" {
  description = "Optional private native SCIM configuration. ECS resolves the external bearer secret; Terraform never reads its value. Set an immutable version for reproducible provisioning. Does not create users, memberships or licenses."
  type = object({
    oidc_issuer                     = string
    bearer_token_secret_arn         = string
    bearer_token_secret_version_id  = optional(string)
    bearer_token_secret_kms_key_arn = optional(string)
  })
  default = null

  validation {
    condition = var.scim_provisioning == null ? true : (
      can(regex("^https://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$", var.scim_provisioning.oidc_issuer)) &&
      can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.scim_provisioning.bearer_token_secret_arn)) &&
      (var.scim_provisioning.bearer_token_secret_version_id == null ? true : can(regex("^[A-Za-z0-9-]{32,64}$", var.scim_provisioning.bearer_token_secret_version_id))) &&
      (var.scim_provisioning.bearer_token_secret_kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.scim_provisioning.bearer_token_secret_kms_key_arn)))
    )
    error_message = "scim_provisioning requires an HTTPS issuer, exact complete bearer secret ARN, optional immutable 32–64 character version ID and optional exact KMS key ARN."
  }
}

locals {
  scim_environment = var.scim_provisioning == null ? {} : {
    Scim__OidcIssuer = var.scim_provisioning.oidc_issuer
  }
  scim_secrets = var.scim_provisioning == null ? [] : [{
    name      = "Scim__BearerToken"
    valueFrom = "${var.scim_provisioning.bearer_token_secret_arn}${var.scim_provisioning.bearer_token_secret_version_id == null ? "" : ":::${var.scim_provisioning.bearer_token_secret_version_id}"}"
  }]
  scim_secret_statements = var.scim_provisioning == null ? [] : concat([
    {
      Sid      = "ScimBearerRead"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.scim_provisioning.bearer_token_secret_arn]
      Condition = var.scim_provisioning.bearer_token_secret_version_id == null ? {} : {
        StringEquals = { "secretsmanager:VersionId" = var.scim_provisioning.bearer_token_secret_version_id }
      }
    }
    ], var.scim_provisioning.bearer_token_secret_version_id == null ? [] : [{
      # Preserve the version ceiling even if another caller-selected secret slot
      # or an attached execution policy also grants this base ARN.
      Sid      = "ScimBearerVersionCeiling"
      Effect   = "Deny"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.scim_provisioning.bearer_token_secret_arn]
      Condition = {
        StringNotEquals = { "secretsmanager:VersionId" = var.scim_provisioning.bearer_token_secret_version_id }
      }
      }], var.scim_provisioning.bearer_token_secret_kms_key_arn == null ? [] : [{
      Sid      = "ScimBearerDecrypt"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = [var.scim_provisioning.bearer_token_secret_kms_key_arn]
      Condition = {
        StringEquals = {
          "kms:ViaService"                  = "secretsmanager.${split(":", var.scim_provisioning.bearer_token_secret_arn)[3]}.amazonaws.com"
          "kms:EncryptionContext:SecretARN" = var.scim_provisioning.bearer_token_secret_arn
        }
      }
  }])
}

resource "terraform_data" "scim_provisioning" {
  lifecycle {
    precondition {
      condition = var.scim_provisioning == null ? true : var.scim_provisioning.bearer_token_secret_kms_key_arn == null ? true : try(
        slice(split(":", var.scim_provisioning.bearer_token_secret_arn), 1, 2) == slice(split(":", var.scim_provisioning.bearer_token_secret_kms_key_arn), 1, 2) &&
        slice(split(":", var.scim_provisioning.bearer_token_secret_arn), 3, 5) == slice(split(":", var.scim_provisioning.bearer_token_secret_kms_key_arn), 3, 5), false
      )
      error_message = "The SCIM bearer CMK must share the bearer secret's partition, region and account."
    }
    precondition {
      condition = alltrue([for name in keys(merge(var.additional_env, var.canary_additional_env)) :
        !contains(["scim__bearertoken", "scim__oidcissuer"], trimprefix(trimprefix(lower(replace(name, ":", "__")), "dotnet_"), "aspnetcore_"))
      ])
      error_message = "Use typed scim_provisioning for SCIM issuer and bearer settings; plaintext and prefixed additional_env overrides are forbidden on both tasks."
    }
  }
}
