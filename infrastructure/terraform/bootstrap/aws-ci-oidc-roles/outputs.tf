output "role_arns" {
  value       = { for key, role in module.oidc : key => role.role_arn }
  description = "Role ARN per consumer; each workflow sets it as role-to-assume once its job declares the matching environment."
}
