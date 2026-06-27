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

# --- GP substrate runtime contract (opaque ARNs the devops agent/server read) -

output "gp_job_queue_arn" {
  description = "GP Fargate Spot Batch job queue ARN."
  value       = module.honua.gp_job_queue_arn
}

output "gp_job_definition_arns" {
  description = "Map of GP job-definition size tier => ARN ({ s, m, l, xl })."
  value       = module.honua.gp_job_definition_arns
}

output "gp_compute_environment_arn" {
  description = "GP Fargate Spot Batch compute environment ARN."
  value       = module.honua.gp_compute_environment_arn
}

output "gp_job_role_arn" {
  description = "GP Batch job (task) role ARN."
  value       = module.honua.gp_job_role_arn
}

output "gp_execution_role_arn" {
  description = "GP Fargate task execution role ARN (ECR pull + log writes)."
  value       = module.honua.gp_execution_role_arn
}

output "gp_worker_gdal_repository_url" {
  description = "Push/pull URL of the dedicated worker-gdal ECR repository (null unless create_worker_gdal_repo)."
  value       = module.honua.gp_worker_gdal_repository_url
}

# --- Custom-code (untrusted) substrate contract (opaque ARNs) ---------------

output "customcode_job_queue_arn" {
  description = "Custom-code Fargate Spot Batch job queue ARN (separate from the GP queue)."
  value       = module.honua.customcode_job_queue_arn
}

output "customcode_job_definition_arns" {
  description = "Map of custom-code job-definition size tier => ARN ({ s, m, l, xl })."
  value       = module.honua.customcode_job_definition_arns
}

output "customcode_task_role_arn" {
  description = "Minimal custom-code task (job) role ARN — NO secrets/DB access, only scoped artifact S3."
  value       = module.honua.customcode_task_role_arn
}

output "customcode_python_repository_url" {
  description = "Push/pull URL of the worker-customcode-python ECR repository (null unless create_worker_customcode_repo)."
  value       = module.honua.customcode_python_repository_url
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
