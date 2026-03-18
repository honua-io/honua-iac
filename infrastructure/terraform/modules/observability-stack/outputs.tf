# --- Infrastructure outputs ---

output "prometheus_release" {
  description = "Prometheus Helm release name."
  value       = helm_release.prometheus.name
}

output "grafana_release" {
  description = "Grafana Helm release name."
  value       = helm_release.grafana.name
}

output "prometheus_url" {
  description = "In-cluster Prometheus URL."
  value       = "http://${var.prometheus_release_name}-server.${var.namespace}.svc.cluster.local"
}

# --- Honua integration outputs ---

output "honua_prometheus_job_name" {
  description = "Prometheus job name used for the Honua scrape target."
  value       = local.honua_scrape_config.job_name
}

output "honua_prometheus_selector" {
  description = "PromQL selector fragment for the Honua scrape target."
  value       = "job=\"${local.honua_scrape_config.job_name}\""
}

output "grafana_url" {
  description = "URL for accessing the Grafana dashboard."
  value       = var.grafana_ingress_enabled && var.grafana_ingress_host != "" ? "${var.grafana_ingress_tls_secret != "" ? "https" : "http"}://${var.grafana_ingress_host}" : "kubectl port-forward svc/${var.grafana_release_name} 3000:80 -n ${var.namespace}"
}

output "grafana_admin_secret_name" {
  description = "Kubernetes secret containing Grafana admin credentials."
  value       = kubernetes_secret_v1.grafana_admin.metadata[0].name
}

output "grafana_admin_secret_keys" {
  description = "Secret data keys for Grafana admin credentials."
  value = {
    username = "admin-user"
    password = "admin-pass"
  }
}

output "dashboard_configmap_name" {
  description = "ConfigMap that provisions the Honua Grafana dashboard."
  value       = kubernetes_config_map_v1.honua_dashboard.metadata[0].name
}

output "opentelemetry_collector_service_name" {
  description = "Service name for the optional OpenTelemetry Collector."
  value       = var.opentelemetry_collector_enabled ? var.opentelemetry_release_name : null
}

output "opentelemetry_collector_metrics_endpoint" {
  description = "In-cluster metrics endpoint for the optional OpenTelemetry Collector."
  value       = var.opentelemetry_collector_enabled ? "http://${var.opentelemetry_release_name}.${var.namespace}.svc.cluster.local:8888/metrics" : null
}

output "opentelemetry_collector_otlp_grpc_endpoint" {
  description = "In-cluster OTLP gRPC endpoint for the optional OpenTelemetry Collector."
  value       = var.opentelemetry_collector_enabled && var.opentelemetry_collector_enable_otlp_receiver ? "${var.opentelemetry_release_name}.${var.namespace}.svc.cluster.local:4317" : null
}

output "opentelemetry_collector_otlp_http_endpoint" {
  description = "In-cluster OTLP HTTP endpoint for the optional OpenTelemetry Collector."
  value       = var.opentelemetry_collector_enabled && var.opentelemetry_collector_enable_otlp_receiver ? "http://${var.opentelemetry_release_name}.${var.namespace}.svc.cluster.local:4318" : null
}

output "operations_metadata" {
  description = "Structured operational metadata for observability runbooks and telemetry onboarding."
  value = {
    namespace = var.namespace
    prometheus = {
      release_name   = helm_release.prometheus.name
      url            = "http://${var.prometheus_release_name}-server.${var.namespace}.svc.cluster.local"
      retention      = var.prometheus_retention
      retention_size = var.prometheus_retention_size
      honua_job_name = local.honua_scrape_config.job_name
      honua_selector = "job=\"${local.honua_scrape_config.job_name}\""
    }
    grafana = {
      release_name        = helm_release.grafana.name
      url                 = var.grafana_ingress_enabled && var.grafana_ingress_host != "" ? "${var.grafana_ingress_tls_secret != "" ? "https" : "http"}://${var.grafana_ingress_host}" : "kubectl port-forward svc/${var.grafana_release_name} 3000:80 -n ${var.namespace}"
      admin_secret_name   = kubernetes_secret_v1.grafana_admin.metadata[0].name
      dashboard_configmap = kubernetes_config_map_v1.honua_dashboard.metadata[0].name
    }
    opentelemetry_collector = {
      enabled                = var.opentelemetry_collector_enabled
      release_name           = var.opentelemetry_collector_enabled ? helm_release.opentelemetry_collector[0].name : null
      service_name           = var.opentelemetry_collector_enabled ? var.opentelemetry_release_name : null
      metrics_endpoint       = var.opentelemetry_collector_enabled ? "http://${var.opentelemetry_release_name}.${var.namespace}.svc.cluster.local:8888/metrics" : null
      otlp_grpc_endpoint     = var.opentelemetry_collector_enabled && var.opentelemetry_collector_enable_otlp_receiver ? "${var.opentelemetry_release_name}.${var.namespace}.svc.cluster.local:4317" : null
      otlp_http_endpoint     = var.opentelemetry_collector_enabled && var.opentelemetry_collector_enable_otlp_receiver ? "http://${var.opentelemetry_release_name}.${var.namespace}.svc.cluster.local:4318" : null
      upstream_otlp_endpoint = var.opentelemetry_collector_enabled && var.opentelemetry_collector_otlp_endpoint != "" ? var.opentelemetry_collector_otlp_endpoint : null
      prometheus_job_name    = var.opentelemetry_collector_enabled ? local.opentelemetry_collector_scrape_config.job_name : null
    }
  }
}

output "opentelemetry_release" {
  description = "OpenTelemetry Collector Helm release name when the optional collector is enabled."
  value       = var.opentelemetry_collector_enabled ? helm_release.opentelemetry_collector[0].name : null
}

output "opentelemetry_otlp_grpc_endpoint" {
  description = "In-cluster OTLP gRPC endpoint for the optional OpenTelemetry Collector."
  value       = var.opentelemetry_collector_enabled && var.opentelemetry_collector_enable_otlp_receiver ? "${var.opentelemetry_release_name}.${var.namespace}.svc.cluster.local:4317" : null
}

output "opentelemetry_otlp_http_endpoint" {
  description = "In-cluster OTLP HTTP endpoint for the optional OpenTelemetry Collector."
  value       = var.opentelemetry_collector_enabled && var.opentelemetry_collector_enable_otlp_receiver ? "http://${var.opentelemetry_release_name}.${var.namespace}.svc.cluster.local:4318" : null
}
