# Observability Stack (Optional Add-On)

This is the architecture-plan placeholder for the optional Prometheus + Grafana
add-on. The implementation, variables, outputs, and bundled assets all live in a
single source of truth:

- Module: [`modules/observability-stack`](../../modules/observability-stack)
- Alert rules: `modules/observability-stack/assets/alerts.yml`
- Dashboard: `modules/observability-stack/assets/honua-overview.json`

The duplicate `assets/` copy that previously lived here was removed so dashboards
and alert rules have one owner and cannot drift. Consume the add-on via the
module directly:

```hcl
module "observability" {
  source = "../../modules/observability-stack"

  namespace            = "honua-observability"
  honua_metrics_target = "honua-honua.default.svc.cluster.local:80"
  helm_timeout_seconds = 900
}
```

See the module README for the full input/output reference and operational notes.
