# Keep the canonical server registry outside Lambda's 4 KB environment limit.
# This document contains configuration identifiers, not credential material.
# Pin each function version to its document version so rolling back a function
# does not silently read a newer deployment target configuration.
locals {
  runtime_settings_document = {
    ControlPlane = {
      DeployTargets = [{
        TargetId                    = local.lambda_target_id
        TargetKind                  = "AwsLambda"
        Backend                     = "honua-gitops-aws-lambda"
        Environment                 = var.environment
        TargetName                  = local.lambda_function_arn
        ArtifactReference           = var.image
        RequiresOutOfBandMigrations = true
        Parameters = {
          "aws.region"            = data.aws_region.current.name
          "aws.lambda.alias_name" = var.lambda_alias_name
          "honua.runtime_kind"    = "aws-lambda"
        }
      }]
    }
  }
}

#checkov:skip=CKV2_AWS_57: Terraform versions this configuration document; automatic credential rotation does not apply.
resource "aws_secretsmanager_secret" "runtime_settings" {
  #checkov:skip=CKV2_AWS_57: Terraform versions this configuration document; automatic credential rotation does not apply.
  name        = "${local.name}/runtime-settings-document"
  description = "Versioned Honua deployment target configuration."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "runtime_settings" {
  secret_id     = aws_secretsmanager_secret.runtime_settings.id
  secret_string = jsonencode(local.runtime_settings_document)

  lifecycle {
    precondition {
      condition = alltrue([
        for key in keys(var.additional_env) :
        !contains(["honua_settings_document", "settings__document", "controlplane__deploytargets"], lower(replace(key, ":", "__"))) &&
        !startswith(lower(replace(key, ":", "__")), "controlplane__deploytargets__")
      ])
      error_message = "The module owns HONUA_SETTINGS_DOCUMENT and ControlPlane:DeployTargets; additional_env cannot replace, override or extend the version-pinned deployment registry."
    }
  }
}
