output "honua_api_endpoint" {
  description = "Honua API Gateway endpoint URL for the cert stack."
  value       = module.honua.api_endpoint
}

output "cert_artifact_bucket" {
  description = "Name of the cert artifact S3 bucket (GP inputs/outputs + certification evidence)."
  value       = aws_s3_bucket.cert_artifacts.bucket
}

output "cert_artifact_bucket_arn" {
  description = "ARN of the cert artifact S3 bucket."
  value       = aws_s3_bucket.cert_artifacts.arn
}

output "gp_batch_job_queue_arn" {
  description = "GP Fargate Spot Batch job queue ARN."
  value       = module.honua.gp_batch_job_queue_arn
}

output "gp_batch_job_definition_arn" {
  description = "GP Batch job definition ARN (current revision)."
  value       = module.honua.gp_batch_job_definition_arn
}

output "gp_batch_job_role_arn" {
  description = "GP Batch job (task) role ARN."
  value       = module.honua.gp_batch_job_role_arn
}

output "worker_gdal_repository_url" {
  description = "Push/pull URL of the dedicated worker-gdal ECR repository (null unless create_worker_gdal_repo)."
  value       = module.honua.worker_gdal_repository_url
}

output "github_oidc_role_arn" {
  description = "Role ARN the GitHub Actions cert workflow assumes via OIDC (role-to-assume in configure-aws-credentials)."
  value       = module.github_oidc.role_arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider (created or reused)."
  value       = module.github_oidc.oidc_provider_arn
}

output "budget_sns_topic_arn" {
  description = "SNS topic ARN that receives the monthly budget threshold notifications."
  value       = aws_sns_topic.budget.arn
}
