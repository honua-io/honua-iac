mock_provider "aws" {
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:123456789012:cert-budget" }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_region" {
    defaults = {
      id     = "us-east-1"
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      partition          = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:us-east-1:123456789012:repository/honua-server"
      registry_id    = "123456789012"
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/honua-test"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/honua-test"
    }
  }

  mock_resource "aws_batch_compute_environment" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:compute-environment/honua-mock"
    }
  }

  mock_resource "aws_batch_job_queue" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:job-queue/honua-mock"
    }
  }

  mock_resource "aws_batch_job_definition" {
    defaults = {
      arn = "arn:aws:batch:us-east-1:123456789012:job-definition/honua-mock:1"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:honua-mock:*"
    }
  }

  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      arn           = "arn:aws:apigateway:us-east-1::/apis/abcdefghij"
      execution_arn = "arn:aws:execute-api:us-east-1:123456789012:abcdefghij"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-mock-AbCdEf"
    }
  }
}

mock_provider "random" {}
mock_provider "null" {}

mock_provider "archive" {}

# Skip the packaging provisioner: this suite makes no network or cloud calls.
override_resource {
  target = terraform_data.postgis_bootstrap_build
  values = {}
}

# Give the runner document a distinct rendered identity so attaching an
# execution-role document by mistake cannot satisfy the wiring assertion.
override_data {
  target = data.aws_iam_policy_document.lambda_preview_certification
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"MockRunnerDocument\",\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"arn:aws:secretsmanager:us-east-1:123456789012:secret:fixture-ABC123\"}]}"
  }
}

variables {
  honua_image                               = "123456789012.dkr.ecr.us-east-1.amazonaws.com/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  honua_admin_password                      = "Synthetic-Cert-Test-Only-Password-254!"
  operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:cert-keyring-ABC123"
  audit_chain_key_secret_arn                = "arn:aws:secretsmanager:us-east-1:123456789012:secret:cert-audit-chain-ABC123"
}

override_resource {
  target = module.honua.aws_secretsmanager_secret.connection_string
  values = {
    arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-cert-cert/connection-string-ABC123"
    name = "honua-cert-cert/connection-string"
  }
}
override_resource {
  target = module.honua.aws_secretsmanager_secret.admin_password
  values = {
    arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-cert-cert/admin-password-ABC123"
    name = "honua-cert-cert/admin-password"
  }
}
override_resource {
  target = module.honua.aws_secretsmanager_secret.master_key
  values = {
    arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-cert-cert/master-key-ABC123"
    name = "honua-cert-cert/master-key"
  }
}
override_resource {
  target = module.honua.aws_secretsmanager_secret.redis_connection[0]
  values = {
    arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-cert-cert/redis-connection-ABC123"
    name = "honua-cert-cert/redis-connection"
  }
}
override_resource {
  target = module.honua.random_password.redis_auth[0]
  values = { result = "aaaaAAAA1111&&&&aaaaAAAA1111&&&&" }
}

run "cert_capture_exact_secret_set" {
  command = apply
  assert {
    condition = toset(local.lambda_preview_secret_arns) == toset([
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-cert-cert/connection-string-ABC123",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-cert-cert/admin-password-ABC123",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-cert-cert/master-key-ABC123",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-cert-cert/redis-connection-ABC123",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:cert-keyring-ABC123",
      "arn:aws:secretsmanager:us-east-1:123456789012:secret:cert-audit-chain-ABC123",
    ])
    error_message = "Cert capture must authorize exactly DB, admin, independent master key, Redis, the explicit keyring and configured audit key; no demo license or wildcard."
  }
  assert {
    condition = alltrue([for statement in data.aws_iam_policy_document.lambda_preview_certification.statement :
      toset(statement.actions) == toset(["secretsmanager:GetSecretValue"]) &&
      toset(statement.resources) == setunion(toset(local.lambda_preview_secret_arns), toset(local.lambda_preview_settings_secret_arns))
      if statement.sid == "CaptureCertificationSecretVersions"
    ]) && length([for statement in data.aws_iam_policy_document.lambda_preview_certification.statement : statement if statement.sid == "CaptureCertificationSecretVersions"]) == 1
    error_message = "The OIDC runner must have its own exact, read-only secret capture statement."
  }
  assert {
    condition = aws_iam_role_policy.lambda_preview_certification.role == "honua-cert-cert-gha" && aws_iam_role_policy.lambda_preview_certification.policy == data.aws_iam_policy_document.lambda_preview_certification.json && length([
      for statement in data.aws_iam_policy_document.lambda_preview_certification.statement : statement
      if anytrue([for action in statement.actions : startswith(action, "secretsmanager:")])
    ]) == 1
    error_message = "The single secret capture grant must attach to the existing OIDC runner, not only the Lambda runtime identity."
  }
  assert {
    condition = alltrue([for document in [data.aws_iam_policy_document.lambda_preview_execution_boundary, data.aws_iam_policy_document.lambda_preview_execution_secrets] :
      length([for statement in document.statement : statement if statement.sid == "CertificationStackSecretsRead" && toset(statement.resources) == setunion(toset(local.lambda_preview_secret_arns), toset(local.lambda_preview_settings_secret_arns)) && toset(statement.actions) == toset(["secretsmanager:GetSecretValue"])]) == 1
    ])
    error_message = "Both runtime grants and the boundary must match the runner's exact secret set, including the keyring."
  }
  assert {
    condition     = toset(values(output.deployment_contract.secret_refs)) == toset(local.lambda_preview_secret_arns) && toset([for ref in values(output.operations_contract.secrets.references) : ref.id]) == toset(local.lambda_preview_secret_arns)
    error_message = "Both emitted contracts must inventory exactly the runtime/capture secret set, including the independent master key and operator-owned keys."
  }
  assert {
    condition     = output.operations_contract.secrets.references.operation_key_ring_certificate.managed_by == "operator" && output.operations_contract.secrets.references.operation_key_ring_certificate.kind == "operation_key_ring_certificate" && output.operations_contract.secrets.references.audit_chain_key.managed_by == "operator" && output.operations_contract.secrets.references.audit_chain_key.kind == "audit_chain_key"
    error_message = "The key-ring and audit-key contract entries must retain their operator ownership and typed secret kinds."
  }
  assert {
    condition     = module.honua.operation_key_ring_certificate_secret_arn == var.operation_key_ring_certificate_secret_arn && module.honua.audit_chain_key_secret_arn == var.audit_chain_key_secret_arn && module.honua.pro_license_secret_arn == null && output.licensing_mode == "Disabled"
    error_message = "The cert root must pass the declared keyring and retain 2026.1 disabled licensing with no license secret."
  }
}

run "reject_keyring_shorthand" {
  command = plan
  variables { operation_key_ring_certificate_secret_arn = "hck" }
  expect_failures = [var.operation_key_ring_certificate_secret_arn]
}
run "reject_keyring_wildcard" {
  command = plan
  variables { operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:cert-*" }
  expect_failures = [var.operation_key_ring_certificate_secret_arn]
}

run "optional_2026_2_license_is_explicit" {
  command = apply
  variables {
    enable_pro_license             = true
    pro_license_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:cert-license-ABC123"
    pro_license_trusted_public_key = "base64url:c3ludGhldGljLXRlc3Qta2V5"
  }
  assert {
    condition     = output.licensing_mode == "Enabled" && length(local.lambda_preview_secret_arns) == 7 && contains(local.lambda_preview_secret_arns, "arn:aws:secretsmanager:us-east-1:123456789012:secret:cert-license-ABC123")
    error_message = "The opt-in 2026.2 path may add only the operator's explicit license ARN; it must remain optional for 2026.1."
  }
}

run "reject_keyring_outside_cert_account" {
  command = plan
  variables { operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:999999999999:secret:cert-keyring-ABC123" }
  expect_failures = [aws_iam_role_policy.lambda_preview_certification]
}
run "reject_keyring_outside_cert_region" {
  command = plan
  variables { operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:cert-keyring-ABC123" }
  expect_failures = [aws_iam_role_policy.lambda_preview_certification]
}

run "reject_audit_key_wildcard" {
  command = plan
  variables { audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:cert-audit-*" }
  expect_failures = [var.audit_chain_key_secret_arn]
}
run "reject_audit_key_outside_cert_account" {
  command = plan
  variables { audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:999999999999:secret:cert-audit-chain-ABC123" }
  expect_failures = [aws_iam_role_policy.lambda_preview_certification]
}

run "reject_license_wildcard" {
  command = plan
  variables {
    enable_pro_license             = true
    pro_license_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:*"
    pro_license_trusted_public_key = "base64url:c3ludGhldGljLXRlc3Qta2V5"
  }
  expect_failures = [var.pro_license_secret_arn]
}
run "reject_license_outside_cert_account" {
  command = plan
  variables {
    enable_pro_license             = true
    pro_license_secret_arn         = "arn:aws:secretsmanager:us-east-1:999999999999:secret:cert-license-ABC123"
    pro_license_trusted_public_key = "base64url:c3ludGhldGljLXRlc3Qta2V5"
  }
  expect_failures = [aws_iam_role_policy.lambda_preview_certification]
}
run "reject_license_outside_cert_region" {
  command = plan
  variables {
    enable_pro_license             = true
    pro_license_secret_arn         = "arn:aws:secretsmanager:us-west-2:123456789012:secret:cert-license-ABC123"
    pro_license_trusted_public_key = "base64url:c3ludGhldGljLXRlc3Qta2V5"
  }
  expect_failures = [aws_iam_role_policy.lambda_preview_certification]
}
run "operator_contract_tracks_changed_keys" {
  command = apply
  variables {
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:other-cert-keyring-DEF456"
    audit_chain_key_secret_arn                = "arn:aws:secretsmanager:us-east-1:123456789012:secret:other-cert-audit-DEF456"
  }
  assert {
    condition     = output.deployment_contract.secret_refs.operation_key_ring_certificate == var.operation_key_ring_certificate_secret_arn && output.deployment_contract.secret_refs.audit_chain_key == var.audit_chain_key_secret_arn && output.operator_contract_digest != run.cert_capture_exact_secret_set.operator_contract_digest
    error_message = "Changing declared operator-owned key references must change the emitted references and contract digest."
  }
}

run "signer_is_runtime_only_and_never_runner_capture" {
  command = apply
  variables {
    transcript_signing = {
      key_id      = "approved-model-key"
      secret_arn  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123"
      version_id  = "00000000-0000-0000-0000-000000000008"
      kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000007"
    }
  }
  assert {
    condition = (
      module.honua.transcript_signing_environment_rendered == tomap({
        StudioAiProxy__TranscriptSigning__KeyId               = "approved-model-key"
        StudioAiProxy__TranscriptSigning__PrivateKeyReference = "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-transcript-ABC123?versionId=00000000-0000-0000-0000-000000000008"
      })
    )
    error_message = "The cert root must pass the exact approved signer identity and immutable runtime reference."
  }
  assert {
    condition = (
      length(local.lambda_preview_secret_arns) == 6 && !contains(local.lambda_preview_secret_arns, var.transcript_signing.secret_arn) &&
      toset(local.lambda_preview_runtime_secret_arns) == setunion(toset(local.lambda_preview_secret_arns), toset(local.lambda_preview_settings_secret_arns), toset([var.transcript_signing.secret_arn]))
    )
    error_message = "Only the preview runtime secret set may include the signer; the runner capture set stays exactly six."
  }
  assert {
    condition = (
      alltrue([for document in [data.aws_iam_policy_document.lambda_preview_execution_boundary, data.aws_iam_policy_document.lambda_preview_execution_secrets] :
        length([for statement in document.statement : statement if statement.sid == "CertificationStackSecretsRead" && toset(statement.resources) == toset(local.lambda_preview_runtime_secret_arns) && toset(statement.actions) == toset(["secretsmanager:GetSecretValue"])]) == 1 &&
      length([for statement in document.statement : statement if statement.sid == "TranscriptSignerDecrypt" && toset(statement.resources) == toset([var.transcript_signing.kms_key_arn]) && toset(statement.actions) == toset(["kms:Decrypt"])]) == 1])
    )
    error_message = "The preview execution boundary and policy must permit exactly the signer secret and its configured KMS key."
  }
  assert {
    condition = (
      alltrue([for statement in data.aws_iam_policy_document.lambda_preview_certification.statement :
      !contains(statement.resources, var.transcript_signing.secret_arn) && !contains(statement.resources, var.transcript_signing.kms_key_arn)]) &&
      !contains(values(output.deployment_contract.secret_refs), var.transcript_signing.secret_arn) &&
      !contains([for reference in values(output.operations_contract.secrets.references) : reference.id], var.transcript_signing.secret_arn)
    )
    error_message = "Runner IAM and operator capture contracts must never authorize or capture the private signing seed."
  }
}

run "reject_signer_reused_as_captured_audit_secret" {
  command = plan
  variables {
    transcript_signing = {
      key_id     = "approved-model-key"
      secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:cert-audit-chain-ABC123"
    }
  }
  expect_failures = [aws_iam_role_policy.lambda_preview_execution_secrets]
}

run "cert_root_rejects_partial_signer_pair" {
  command = plan
  variables {
    transcript_signing = {
      key_id     = "approved-model-key"
      secret_arn = ""
    }
  }
  expect_failures = [var.transcript_signing]
}
