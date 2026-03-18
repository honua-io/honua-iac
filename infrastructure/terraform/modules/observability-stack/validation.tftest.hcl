mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}

variables {
  honua_metrics_target = "honua.default.svc.cluster.local:8080"
}

run "collector_disabled_by_default" {
  command = plan

  assert {
    condition     = output.opentelemetry_release == null
    error_message = "Expected no OpenTelemetry release when the collector is disabled."
  }

  assert {
    condition     = output.operations_metadata.opentelemetry_collector.enabled == false
    error_message = "Expected operations metadata to reflect that the collector is disabled."
  }
}

run "collector_enabled" {
  command = plan

  variables {
    opentelemetry_collector_enabled = true
  }

  assert {
    condition     = output.opentelemetry_release == "honua-otel"
    error_message = "Expected the default OpenTelemetry release name."
  }

  assert {
    condition     = output.opentelemetry_collector_metrics_endpoint == "http://honua-otel.honua-observability.svc.cluster.local:8888/metrics"
    error_message = "Expected the collector metrics endpoint to use the in-cluster service DNS name."
  }
}
