output "state_config" {
  description = "Controller-only agent_e2e_state.py configuration; not agent public inputs."
  value = {
    region = var.region
    bucket = aws_s3_bucket.state.id
    table  = aws_dynamodb_table.history["state"].name
  }
}

output "claim_table_name" {
  description = "Pass only to Terraform-defined worker lifecycle roles; separate from the candidate state head."
  value       = aws_dynamodb_table.history["claims"].name
}

output "evidence_prefix" {
  value = local.evidence_prefix
}

output "candidate_digest" {
  value = var.candidate_digest
}
