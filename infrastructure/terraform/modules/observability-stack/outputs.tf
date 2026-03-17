// Pass through the canonical platform/component outputs.

output "prometheus_release" {
  value = module.platform.prometheus_release
}

output "grafana_release" {
  value = module.platform.grafana_release
}

output "prometheus_url" {
  value = module.platform.prometheus_url
}

output "honua_prometheus_job_name" {
  value = module.platform.honua_prometheus_job_name
}

output "honua_prometheus_selector" {
  value = module.platform.honua_prometheus_selector
}

output "grafana_url" {
  value = module.platform.grafana_url
}

output "grafana_admin_secret_name" {
  value = module.platform.grafana_admin_secret_name
}

output "grafana_admin_secret_keys" {
  value = module.platform.grafana_admin_secret_keys
}

output "dashboard_configmap_name" {
  value = module.platform.dashboard_configmap_name
}
