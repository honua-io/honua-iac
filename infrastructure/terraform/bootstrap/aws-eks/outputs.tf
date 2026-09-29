output "user_name" {
  value = aws_iam_user.terraform.name
}

output "policy_arn" {
  value = aws_iam_policy.terraform.arn
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

output "supported_for_release" {
  description = "HARD MARKER: always false. This bootstrap path cannot satisfy the AWS release/certification lane."
  value       = false
}

output "release_posture" {
  description = "HARD MARKER consumed by the release lane. Names why this path is unsupported and where the certified path lives."
  value = {
    schema_version        = "v1"
    supported_for_release = false
    posture               = "unsupported-local-only"
    credential_kind       = var.create_access_key ? "long-lived-iam-access-key" : "long-lived-iam-user"
    certified_alternative = "infrastructure/terraform/bootstrap/aws-exec-identity"
    reason                = "Creates a long-lived IAM user principal. The certified lane requires short-lived SSO/OIDC/STS federation and creates no IAM user or access key."
  }
}
