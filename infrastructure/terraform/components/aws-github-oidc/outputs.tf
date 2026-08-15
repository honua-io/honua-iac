output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider (created or reused)."
  value       = local.oidc_provider_arn
}

output "role_arn" {
  description = "ARN of the role the GitHub Actions cert workflow assumes via OIDC. Set this as the role-to-assume in aws-actions/configure-aws-credentials."
  value       = aws_iam_role.github_actions.arn
}

output "role_name" {
  description = "Name of the GitHub Actions cert role."
  value       = aws_iam_role.github_actions.name
}

output "oidc_subjects" {
  description = "The `sub` claim patterns the role trust policy authorizes."
  value       = local.oidc_subjects
}
