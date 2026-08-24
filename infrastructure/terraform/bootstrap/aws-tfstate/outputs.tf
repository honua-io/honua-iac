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

output "state_lock_table_name" {
  description = "DynamoDB state-lock table name."
  value       = aws_dynamodb_table.lock.name
}

output "state_key" {
  description = "Exclusive stack/environment state object key."
  value       = local.state_key
}
