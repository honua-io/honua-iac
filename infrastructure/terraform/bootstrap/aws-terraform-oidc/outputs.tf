output "role_arn" {
  description = "Short-lived backend access role ARN."
  value       = aws_iam_role.backend_access.arn
}

output "role_name" {
  description = "Short-lived backend access role name."
  value       = aws_iam_role.backend_access.name
}

output "workload_identity_contract" {
  description = "Evidence-safe OIDC/STS backend access contract; no token or secret is emitted."
  value       = local.workload_identity_contract
}

output "workload_identity_contract_digest" {
  description = "SHA-256 digest of the canonical workload identity contract."
  value       = sha256(jsonencode(local.workload_identity_contract))
}
