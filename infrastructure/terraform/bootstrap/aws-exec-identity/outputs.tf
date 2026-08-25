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
