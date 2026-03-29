output "user_name" {
  value       = try(aws_iam_user.terraform[0].name, null)
  description = "Name of the fallback Terraform IAM user when create_iam_user is enabled."
}

output "policy_arn" {
  value       = aws_iam_policy.terraform.arn
  description = "ARN of the bootstrap IAM policy attached to the Terraform identity surface."
}

output "access_key_id" {
  value       = try(aws_iam_access_key.terraform[0].id, null)
  description = "Access key ID for the Terraform IAM user."
}

output "secret_access_key" {
  value       = try(aws_iam_access_key.terraform[0].secret, null)
  description = "Secret access key for the Terraform IAM user."
  sensitive   = true
}

output "role_arn" {
  value       = try(aws_iam_role.terraform[0].arn, null)
  description = "ARN of the workload-identity Terraform role when OIDC federation is configured."
}

output "bootstrap_identity_contract" {
  description = "Structured contract describing the supported authentication surfaces for this bootstrap identity."
  value = {
    schema_version     = "v1"
    auth_mode          = trimspace(var.oidc_provider_arn) != "" && length(var.oidc_subjects) > 0 ? "workload_identity" : (var.create_access_key ? "access_key" : (var.create_iam_user ? "iam_user" : "policy_only"))
    policy_arn         = aws_iam_policy.terraform.arn
    user_name          = try(aws_iam_user.terraform[0].name, null)
    role_arn           = try(aws_iam_role.terraform[0].arn, null)
    oidc_provider_arn  = trimspace(var.oidc_provider_arn) != "" ? var.oidc_provider_arn : null
    oidc_subjects      = length(var.oidc_subjects) > 0 ? var.oidc_subjects : null
    oidc_audiences     = length(var.oidc_audiences) > 0 ? var.oidc_audiences : null
    access_key_enabled = var.create_access_key
  }
}
