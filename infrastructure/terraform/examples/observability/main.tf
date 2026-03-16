provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

module "observability" {
  source = "../../modules/observability-stack"

  namespace                      = var.namespace
  honua_metrics_target           = var.honua_metrics_target
  alertmanager_enabled           = var.alertmanager_enabled
  prometheus_persistence_enabled = var.prometheus_persistence_enabled
  grafana_persistence_enabled    = var.grafana_persistence_enabled
  helm_timeout_seconds           = var.helm_timeout_seconds

  grafana_ingress_enabled = var.grafana_ingress_host != ""
  grafana_ingress_host    = var.grafana_ingress_host
}

locals {
  infrastructure_outputs = {
    namespace = var.namespace
    monitoring = {
      prometheus_url            = module.observability.prometheus_url
      honua_prometheus_job_name = module.observability.honua_prometheus_job_name
      honua_prometheus_selector = module.observability.honua_prometheus_selector
      grafana_url               = module.observability.grafana_url
      grafana_admin_secret_name = module.observability.grafana_admin_secret_name
    }
  }
}

output "prometheus_url" {
  value = module.observability.prometheus_url
}

output "honua_prometheus_job_name" {
  value = module.observability.honua_prometheus_job_name
}

output "honua_prometheus_selector" {
  value = module.observability.honua_prometheus_selector
}

output "grafana_url" {
  value = module.observability.grafana_url
}

output "grafana_admin_secret_name" {
  value = module.observability.grafana_admin_secret_name
}

output "infrastructure_outputs" {
  value = local.infrastructure_outputs
}
