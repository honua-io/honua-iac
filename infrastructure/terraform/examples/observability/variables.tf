variable "kubeconfig_path" {
  description = "Path to kubeconfig file."
  type        = string
  default     = "~/.kube/config"
}

variable "namespace" {
  description = "Observability namespace."
  type        = string
  default     = "honua-observability"
}

variable "honua_metrics_target" {
  description = "Honua metrics endpoint target in host:port form."
  type        = string
}

variable "grafana_ingress_host" {
  description = "Optional Grafana ingress host. Leave empty to disable ingress."
  type        = string
  default     = ""
}

variable "helm_timeout_seconds" {
  description = "Helm timeout for Prometheus/Grafana installs."
  type        = number
  default     = 900
}

variable "opentelemetry_collector_enabled" {
  description = "Deploy the optional in-cluster OpenTelemetry Collector gateway."
  type        = bool
  default     = false
}

variable "opentelemetry_chart_version" {
  description = "Optional OpenTelemetry Collector chart version."
  type        = string
  default     = ""
}

variable "opentelemetry_collector_otlp_endpoint" {
  description = "Optional upstream OTLP endpoint for forwarding telemetry."
  type        = string
  default     = ""
}

variable "opentelemetry_collector_otlp_insecure" {
  description = "Disable TLS verification for the upstream OTLP exporter."
  type        = bool
  default     = false
}
