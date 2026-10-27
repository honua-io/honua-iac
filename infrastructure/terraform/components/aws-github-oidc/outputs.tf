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
  description = "The exact `sub` claim values (StringEquals) the cert role trust policy authorizes."
  value       = local.oidc_subjects
}

output "hosted_pilot_bootstrap_role_arn" {
  description = "ARN of the hosted-pilot bootstrap executor role (null when disabled). Set it as the HONUA_AWS_HOSTED_PILOT_BOOTSTRAP_ROLE_ARN repository variable in honua-io/honua-iac."
  value       = one(aws_iam_role.hosted_pilot_bootstrap[*].arn)
}

output "hosted_pilot_bootstrap_oidc_subjects" {
  description = "The exact `sub` values the hosted-pilot bootstrap role trust authorizes (empty when disabled)."
  value       = var.hosted_pilot_bootstrap_role_enabled ? var.hosted_pilot_bootstrap_oidc_subjects : []
}

output "trust_policy_json" {
  description = "Rendered trust policy of the federated role (for consumers' tests and review)."
  value       = data.aws_iam_policy_document.trust.json
}

output "cert_policy_names" {
  description = "Names of the certification permission policies attached (empty when cert_permissions_enabled = false)."
  value       = aws_iam_role_policy.permissions[*].name
}
