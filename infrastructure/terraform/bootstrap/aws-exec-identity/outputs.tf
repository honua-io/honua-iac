output "deployment_role_arn" {
  description = "Infrastructure deployment role ARN. Pass this to the AWS provider's assume_role block."
  value       = aws_iam_role.deployment.arn
}

output "deployment_role_name" {
  description = "Infrastructure deployment role name."
  value       = aws_iam_role.deployment.name
}

output "deployment_policy_arn" {
  description = "ARN of the deployment permission policy."
  value       = aws_iam_policy.deployment.arn
}

output "execution_identity_contract" {
  description = "Evidence-safe execution identity contract: role separation, federation references, and session bounds. No token, credential, or secret is emitted."
  value       = local.execution_identity_contract
}

output "execution_identity_contract_digest" {
  description = "SHA-256 digest of the canonical execution identity contract."
  value       = sha256(jsonencode(local.execution_identity_contract))
}

output "long_lived_credentials_created" {
  description = "Hard marker consumed by the release lane. This root creates no IAM user and no access key, ever."
  value       = false
}

# --- Approval-receipt MAC key (honua-devops#175) ----------------------------

output "approval_mac_key_arn" {
  description = "ARN of the KMS HMAC key backing approval receipts. Pass it to honua-devops as HONUA_DEVOPS_PROVISION_APPROVAL_ISSUER_KEY_ARNS (issuer=arn). Null when enable_approval_mac_key is false."
  value       = local.approval_mac_key_arn
}

output "approval_mac_key_alias" {
  description = "Alias of the approval MAC key. Recorded for operators; honua-devops is configured with the full ARN, not the alias."
  value       = one(aws_kms_alias.approval_mac[*].name)
}

output "approval_mac_generate_policy_arn" {
  description = "ARN of the kms:GenerateMac-only policy attached to the approval issuer roles."
  value       = one(aws_iam_policy.approval_mac_generate[*].arn)
}

output "approval_mac_verify_policy_arn" {
  description = "ARN of the kms:VerifyMac-only policy attached to the approval verifier roles."
  value       = one(aws_iam_policy.approval_mac_verify[*].arn)
}

output "approval_mac_contract" {
  description = "Evidence-safe record of the approval-receipt MAC separation: which principals hold which single action, where the split is enforced, and that the key is not exportable. Carries no key material."
  value       = local.approval_mac_contract
}

output "approval_mac_contract_digest" {
  description = "SHA-256 digest of the canonical approval MAC contract."
  value       = sha256(jsonencode(local.approval_mac_contract))
}
