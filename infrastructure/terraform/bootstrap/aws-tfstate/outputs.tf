output "backend_contract" {
  description = "Evidence-safe remote backend identity and locking contract. Contains no credentials or state contents."
  value       = local.backend_contract
}

output "backend_contract_digest" {
  description = "SHA-256 digest of the canonical backend contract JSON."
  value       = sha256(jsonencode(local.backend_contract))
}

output "state_bucket_name" {
  description = "S3 state bucket name."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "S3 state bucket ARN."
  value       = aws_s3_bucket.state.arn
}

output "state_lock_table_name" {
  description = "DynamoDB state-lock table name, or null when locking on the S3 native lockfile."
  value       = local.create_lock_table ? aws_dynamodb_table.lock[0].name : null
}

output "state_key" {
  description = "Exclusive stack/environment state object key."
  value       = local.state_key
}

output "state_keys" {
  description = "Every exclusive state object key this bucket serves, keyed by stack/environment."
  value       = local.state_keys
}

output "lock_mode" {
  description = "Locking primitive in effect for this backend."
  value       = local.lock_contract.kind
}

output "minimum_terraform_version" {
  description = "Lowest Terraform version that can consume this backend's locking primitive."
  value       = local.lock_contract.min_terraform_version
}

output "backend_access_policy_arn" {
  description = "ARN of the least-privilege managed policy for state object and lock access."
  value       = var.create_backend_access_policy ? aws_iam_policy.backend_access[0].arn : null
}
