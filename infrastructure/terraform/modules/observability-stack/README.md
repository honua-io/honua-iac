# Observability Stack Module (Optional Add-On)

Deploys an optional Prometheus + Grafana stack on Kubernetes using Helm.

This module is intentionally separate from core Honua deployment modules so the
base platform can run without self-hosted observability components.

## What it provisions

- Prometheus Helm release (`prometheus-community/prometheus`)
- Grafana Helm release (`grafana/grafana`)
- Configurable Honua scrape job (`honua_metrics_path` + optional `honua_metrics_format`)
- Alert rules loaded from `assets/alerts.yml`
- Honua dashboard provisioning from `assets/honua-overview.json`
- Grafana admin credentials in a Kubernetes secret

## Usage

```hcl
module "observability" {
  source = "../../modules/observability-stack"

  namespace            = "honua-observability"
  honua_metrics_target = "honua-honua.default.svc.cluster.local:80"
  helm_timeout_seconds = 900

  grafana_ingress_enabled = true
  grafana_ingress_host    = "grafana.example.com"
}
```

Defaults for `alert_rules_file` and `honua_dashboard_file` are bundled with this
module under `assets/`, so callers do not need a matching monorepo checkout.

Honua exposes native Prometheus text metrics at `/metrics` by default. Keep `honua_metrics_path` at `/metrics` unless you override `Observability:Prometheus:Path` in the server configuration.

## Outputs

- `prometheus_url`
- `honua_prometheus_job_name`
- `honua_prometheus_selector`
- `grafana_url`
- `grafana_admin_secret_name`
- `grafana_admin_secret_keys`
- `dashboard_configmap_name`

## Operational notes

- Keep alert rules in `assets/alerts.yml` and update runbooks in `docs/devops/runbooks/`.
- For managed-cloud monitoring, prefer `docs/alerting/` and forward OTLP to managed Prometheus.
- Treat this module as optional for environments that require in-cluster dashboards.
