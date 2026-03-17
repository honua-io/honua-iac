// Compatibility example wrapper around the canonical customer stack.

module "stack" {
  source = "../../stacks/customer/observability"

  kubeconfig_path                = var.kubeconfig_path
  namespace                      = var.namespace
  honua_metrics_target           = var.honua_metrics_target
  grafana_ingress_host           = var.grafana_ingress_host
  alertmanager_enabled           = var.alertmanager_enabled
  prometheus_persistence_enabled = var.prometheus_persistence_enabled
  grafana_persistence_enabled    = var.grafana_persistence_enabled
  helm_timeout_seconds           = var.helm_timeout_seconds
}

output "prometheus_url" {
  value = module.stack.prometheus_url
}

output "honua_prometheus_job_name" {
  value = module.stack.honua_prometheus_job_name
}

output "honua_prometheus_selector" {
  value = module.stack.honua_prometheus_selector
}

output "grafana_url" {
  value = module.stack.grafana_url
}

output "grafana_admin_secret_name" {
  value = module.stack.grafana_admin_secret_name
}

output "infrastructure_outputs" {
  value = module.stack.infrastructure_outputs
}
