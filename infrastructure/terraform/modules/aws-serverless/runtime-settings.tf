# Keep the canonical server registry outside Lambda's 4 KB environment limit.
# lambda_deploy_canary (lambda-canary.tf) adds canary/telemetry parameters and a
# CloudWatch telemetry connection; unset, the document is unchanged.
# enable_rds_proxy adds Database:QueryCache:EnableAutomaticCaching=false
# (local.db_proxy_settings_document, rds-proxy.tf); without the proxy the
# document is unchanged.
# This document contains configuration identifiers, not credential material.
# Pin each function version to its document version so rolling back a function
# does not silently read a newer deployment target configuration.
locals {
  runtime_settings_document = merge(local.db_proxy_settings_document, {
    ControlPlane = merge(local.lambda_deploy_canary_telemetry_connections, {
      DeployTargets = [{
        TargetId                    = local.lambda_target_id
        TargetKind                  = "AwsLambda"
        Backend                     = "honua-gitops-aws-lambda"
        Environment                 = var.environment
        TargetName                  = local.lambda_function_arn
        ArtifactReference           = var.image
        RequiresOutOfBandMigrations = true
        Parameters = merge({
          "aws.region"            = data.aws_region.current.name
          "aws.lambda.alias_name" = var.lambda_alias_name
          "honua.runtime_kind"    = "aws-lambda"
        }, local.lambda_deploy_canary_parameters)
      }]
    })
  })
  runtime_settings_json = jsonencode(local.runtime_settings_document)
  runtime_settings_hash = sha256(local.runtime_settings_json)
  runtime_settings_documents = merge(
    var.retained_runtime_settings_documents,
    { (local.runtime_settings_hash) = local.runtime_settings_json }
  )
}

# Each document gets its own secret, with exactly one AWSCURRENT version.
# Published Lambda versions pin that secret and version. A later deployment
# cannot deprecate the old version through Secrets Manager's version cleanup.
# The previous current document must be carried in the Git-owned retained map
# before a changed document can be applied: prevent_destroy refuses omissions.
#checkov:skip=CKV2_AWS_57: Immutable configuration identifiers, not credentials; rotation does not apply.
resource "aws_secretsmanager_secret" "runtime_settings" {
  #checkov:skip=CKV2_AWS_57: Immutable configuration identifiers, not credentials; rotation does not apply.
  for_each = local.runtime_settings_documents

  name        = "${local.name}/runtime-settings-${each.key}"
  description = "Immutable Honua deployment target configuration ${each.key}."
  tags        = local.tags
  depends_on  = [terraform_data.lambda_secrets_policy_budget]

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "runtime_settings" {
  for_each = local.runtime_settings_documents

  secret_id     = aws_secretsmanager_secret.runtime_settings[each.key].id
  secret_string = each.value

  lifecycle {
    prevent_destroy = true

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
