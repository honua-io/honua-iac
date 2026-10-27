output "demo_infra_drift_role_arn" {
  description = "Plan-only role for honua-demo-infra drift-plan.yml. Set it as the HONUA_DEMO_DRIFT_ROLE_ARN variable of the honua-demo-infra demo-drift environment."
  value       = module.oidc["demo_infra"].role_arn
}

output "iac_bootstrap_drift_role_arn" {
  description = "Plan-only role for honua-iac bootstrap-drift-plan.yml. Set it as the HONUA_BOOTSTRAP_DRIFT_ROLE_ARN variable of the honua-iac bootstrap-drift environment."
  value       = module.oidc["iac_bootstrap"].role_arn
}

output "oidc_subjects" {
  description = "Exact `sub` values each role trusts."
  value       = { for key, mod in module.oidc : key => mod.oidc_subjects }
}
