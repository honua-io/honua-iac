// Compatibility wrapper around the canonical implementation.

module "platform" {
  source = "../../components/observability"

  namespace                      = var.namespace
  create_namespace               = var.create_namespace
  prometheus_release_name        = var.prometheus_release_name
  grafana_release_name           = var.grafana_release_name
  prometheus_chart_version       = var.prometheus_chart_version
  grafana_chart_version          = var.grafana_chart_version
  honua_metrics_target           = var.honua_metrics_target
  honua_metrics_path             = var.honua_metrics_path
  honua_metrics_format           = var.honua_metrics_format
  scrape_interval                = var.scrape_interval
  evaluation_interval            = var.evaluation_interval
  alert_rules_file               = var.alert_rules_file
  honua_dashboard_file           = var.honua_dashboard_file
  alertmanager_enabled           = var.alertmanager_enabled
  prometheus_persistence_enabled = var.prometheus_persistence_enabled
  prometheus_persistence_size    = var.prometheus_persistence_size
  grafana_persistence_enabled    = var.grafana_persistence_enabled
  grafana_persistence_size       = var.grafana_persistence_size
  grafana_ingress_enabled        = var.grafana_ingress_enabled
  grafana_ingress_host           = var.grafana_ingress_host
  grafana_ingress_class_name     = var.grafana_ingress_class_name
  grafana_ingress_annotations    = var.grafana_ingress_annotations
  grafana_admin_user             = var.grafana_admin_user
  prometheus_retention           = var.prometheus_retention
  prometheus_retention_size      = var.prometheus_retention_size
  grafana_ingress_tls_secret     = var.grafana_ingress_tls_secret
  helm_timeout_seconds           = var.helm_timeout_seconds
}
