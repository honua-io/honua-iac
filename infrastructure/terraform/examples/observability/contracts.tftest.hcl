mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  honua_metrics_target = "honua.monitoring.svc.cluster.local:8080"
}

override_module {
  target = module.observability
  outputs = {
    prometheus_url            = "http://prometheus.honua-observability.svc.cluster.local"
    honua_prometheus_job_name = "honua"
    honua_prometheus_selector = "app=honua"
    grafana_url               = "https://grafana.example.test"
    grafana_admin_secret_name = "grafana-admin"
  }
}

run "observability_groups_operator_outputs" {
  command = plan

  assert {
    condition     = output.infrastructure_outputs.monitoring.grafana_url == "https://grafana.example.test"
    error_message = "observability should group monitoring URLs through infrastructure_outputs."
  }

  assert {
    condition     = output.honua_prometheus_job_name == "honua"
    error_message = "observability should keep legacy outputs available for existing automation."
  }
}
