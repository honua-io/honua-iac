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

variable "alertmanager_enabled" {
  description = "Enable Alertmanager in the Prometheus chart."
  type        = bool
  default     = true
}

variable "prometheus_persistence_enabled" {
  description = "Enable Prometheus persistence."
  type        = bool
  default     = true
}

variable "grafana_persistence_enabled" {
  description = "Enable Grafana persistence."
  type        = bool
  default     = true
}

variable "helm_timeout_seconds" {
  description = "Timeout in seconds for Helm release install/upgrade operations."
  type        = number
  default     = 900
}
