# Observability Stack Module (Optional Add-On)

Deploys an optional Prometheus + Grafana stack on Kubernetes using Helm.

This module is intentionally separate from core Honua deployment modules so the
base platform can run without self-hosted observability components.

## Pin to a release

This is a **Tier 2 add-on**: it is published alongside the Tier 1 runtime
modules, but its contract may move faster, so expect more frequent minor bumps.
For a versioned, external pin, consume it by Git source at a SemVer tag. (The
Honua repos are ELv2-licensed, so the public Terraform Registry is not used —
see [`docs/module-versioning.md`](../../../../docs/module-versioning.md).)

```hcl
module "observability" {
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/observability-stack?ref=v0.1.0"
  # ...inputs below...
}
```

Bump `?ref=` to move to a newer release and run `terraform init -upgrade`.

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
