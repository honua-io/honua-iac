output "role_arn" {
  description = "Apply role for honua-demo-infra terraform.yml. Set it as the HONUA_DEMO_DEPLOY_ROLE_ARN variable of the honua-demo-infra `demo` environment."
  value       = module.oidc.role_arn
}

output "oidc_subjects" {
  description = "Exact `sub` values the apply role trusts."
  value       = module.oidc.oidc_subjects
}
