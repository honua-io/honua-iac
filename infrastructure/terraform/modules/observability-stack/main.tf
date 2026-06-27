locals {
  default_alert_rules_file = "${path.module}/assets/alerts.yml"
  default_dashboard_file   = "${path.module}/assets/honua-overview.json"
  alert_rules_file         = var.alert_rules_file != "" ? var.alert_rules_file : local.default_alert_rules_file
  honua_dashboard_file     = var.honua_dashboard_file != "" ? var.honua_dashboard_file : local.default_dashboard_file
  alert_rules              = yamldecode(file(local.alert_rules_file))

  # Explicit Alertmanager routing. Without a config, the chart's Alertmanager
  # starts with a placeholder route that delivers nowhere, so alerts fire into
  # the void. The default below gives real grouping/route structure and a
  # single "default" receiver; when alertmanager_receiver_webhook_url is set it
  # is wired as a live webhook. Operators can override the whole object via
  # var.alertmanager_config.
  default_alertmanager_config = {
    route = {
      group_by        = ["alertname", "severity"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "3h"
      receiver        = "default"
      routes = [
        {
          matchers        = ["severity = critical"]
          receiver        = "default"
          group_wait      = "10s"
          repeat_interval = "1h"
          continue        = false
        }
      ]
    }
    receivers = [
      merge(
        { name = "default" },
        var.alertmanager_receiver_webhook_url != "" ? {
          webhook_configs = [
            {
              url           = var.alertmanager_receiver_webhook_url
              send_resolved = true
            }
          ]
        } : {}
      )
    ]
    inhibit_rules = [
      {
        source_matchers = ["severity = critical"]
        target_matchers = ["severity = warning"]
        equal           = ["alertname"]
      }
    ]
  }

  alertmanager_config = var.alertmanager_config != null ? var.alertmanager_config : local.default_alertmanager_config

  honua_scrape_config = merge(
    {
      job_name     = "honua"
      metrics_path = var.honua_metrics_path
      static_configs = [
        {
          targets = [var.honua_metrics_target]
        }
      ]
    },
    var.honua_metrics_format != "" ? {
      params = {
        format = [var.honua_metrics_format]
      }
    } : {}
  )

  prometheus_values = {
    alertmanager = merge(
      {
        enabled = var.alertmanager_enabled
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi"
          }
        }
      },
      var.alertmanager_enabled ? { config = local.alertmanager_config } : {}
    )
    kube-state-metrics = {
      enabled = false
    }
    prometheus-node-exporter = {
      enabled = false
    }
    server = {
      global = {
        scrape_interval     = var.scrape_interval
        evaluation_interval = var.evaluation_interval
      }
      persistentVolume = {
        enabled = var.prometheus_persistence_enabled
        size    = var.prometheus_persistence_size
      }
      retention     = var.prometheus_retention
      retentionSize = var.prometheus_retention_size
      resources = {
        requests = {
          cpu    = "250m"
          memory = "512Mi"
        }
        limits = {
          cpu    = "1"
          memory = "2Gi"
        }
      }
    }
    extraScrapeConfigs = yamlencode([
      local.honua_scrape_config
    ])
    serverFiles = {
      "alerting_rules.yml" = local.alert_rules
    }
  }

  prometheus_server_url = "http://${var.prometheus_release_name}-server.${var.namespace}.svc.cluster.local"

  grafana_values = {
    admin = {
      existingSecret = kubernetes_secret_v1.grafana_admin.metadata[0].name
      userKey        = "admin-user"
      passwordKey    = "admin-pass"
    }
    persistence = {
      enabled = var.grafana_persistence_enabled
      size    = var.grafana_persistence_size
    }
    datasources = {
      "datasources.yaml" = {
        apiVersion = 1
        datasources = [
          {
            name      = "Prometheus"
            type      = "prometheus"
            access    = "proxy"
            url       = local.prometheus_server_url
            isDefault = true
            editable  = false
          }
        ]
      }
    }
    dashboardProviders = {
      "dashboardproviders.yaml" = {
        apiVersion = 1
        providers = [
          {
            name            = "honua"
            orgId           = 1
            folder          = "Honua"
            type            = "file"
            disableDeletion = true
            editable        = true
            options = {
              path = "/var/lib/grafana/dashboards/honua"
            }
          }
        ]
      }
    }
    dashboardsConfigMaps = {
      honua = kubernetes_config_map_v1.honua_dashboard.metadata[0].name
    }
    ingress = {
      enabled          = var.grafana_ingress_enabled
      ingressClassName = var.grafana_ingress_class_name
      annotations      = var.grafana_ingress_annotations
      hosts            = var.grafana_ingress_host != "" ? [var.grafana_ingress_host] : []
      tls = var.grafana_ingress_tls_secret != "" ? [{
        secretName = var.grafana_ingress_tls_secret
        hosts      = [var.grafana_ingress_host]
      }] : []
    }
    resources = {
      requests = {
        cpu    = "100m"
        memory = "256Mi"
      }
      limits = {
        cpu    = "500m"
        memory = "512Mi"
      }
    }
  }
}

resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace
  }
}

resource "random_password" "grafana_admin" {
  length  = 32
  special = true
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "${var.grafana_release_name}-admin"
    namespace = var.namespace
  }

  data = {
    "admin-user" = var.grafana_admin_user
    "admin-pass" = random_password.grafana_admin.result
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_config_map_v1" "honua_dashboard" {
  metadata {
    name      = "honua-overview-dashboard"
    namespace = var.namespace
  }

  data = {
    "honua-overview.json" = file(local.honua_dashboard_file)
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "helm_release" "prometheus" {
  name             = var.prometheus_release_name
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "prometheus"
  version          = var.prometheus_chart_version
  namespace        = var.namespace
  create_namespace = false
  timeout          = var.helm_timeout_seconds

  values = [yamlencode(local.prometheus_values)]

  depends_on = [kubernetes_namespace_v1.this]
}

resource "helm_release" "grafana" {
  name             = var.grafana_release_name
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "grafana"
  version          = var.grafana_chart_version
  namespace        = var.namespace
  create_namespace = false
  timeout          = var.helm_timeout_seconds

  values = [yamlencode(local.grafana_values)]

  depends_on = [
    kubernetes_namespace_v1.this,
    helm_release.prometheus,
    kubernetes_secret_v1.grafana_admin,
    kubernetes_config_map_v1.honua_dashboard,
  ]
}
