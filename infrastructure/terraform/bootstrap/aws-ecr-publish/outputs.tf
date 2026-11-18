output "role_arn" {
  value       = module.oidc.role_arn
  description = "Role honua-server publish jobs assume in the publish-images environment."
}
