locals {
  default_alert_rules_file   = "${path.module}/assets/alerts.yml"
  default_dashboard_file     = "${path.module}/assets/honua-overview.json"
  alert_rules_file           = var.alert_rules_file != "" ? var.alert_rules_file : local.default_alert_rules_file
  honua_dashboard_file       = var.honua_dashboard_file != "" ? var.honua_dashboard_file : local.default_dashboard_file
  alert_rules                = yamldecode(file(local.alert_rules_file))
  opentelemetry_service_host = "${var.opentelemetry_release_name}.${var.namespace}.svc.cluster.local"

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
  opentelemetry_collector_scrape_config = {
    job_name     = "opentelemetry-collector"
    metrics_path = "/metrics"
    static_configs = [
      {
        targets = ["${local.opentelemetry_service_host}:8888"]
      }
    ]
  }
  opentelemetry_collector_exporters = merge(
    var.opentelemetry_collector_enable_debug_exporter ? {
      debug = {
        verbosity = "basic"
      }
    } : {},
    var.opentelemetry_collector_otlp_endpoint != "" ? {
      otlp = {
        endpoint = var.opentelemetry_collector_otlp_endpoint
        tls = {
          insecure = var.opentelemetry_collector_otlp_insecure
        }
        headers = var.opentelemetry_collector_otlp_headers
      }
    } : {}
  )
  opentelemetry_collector_exporter_names = keys(local.opentelemetry_collector_exporters)
  opentelemetry_collector_receivers = var.opentelemetry_collector_enable_otlp_receiver ? {
    otlp = {
      protocols = {
        grpc = {
          endpoint = "0.0.0.0:4317"
        }
        http = {
          endpoint = "0.0.0.0:4318"
        }
      }
    }
  } : {}
  opentelemetry_collector_pipelines = var.opentelemetry_collector_enable_otlp_receiver && length(local.opentelemetry_collector_exporter_names) > 0 ? {
    logs = {
      receivers  = ["otlp"]
      processors = ["memory_limiter", "batch"]
      exporters  = local.opentelemetry_collector_exporter_names
    }
    metrics = {
      receivers  = ["otlp"]
      processors = ["memory_limiter", "batch"]
      exporters  = local.opentelemetry_collector_exporter_names
    }
    traces = {
      receivers  = ["otlp"]
      processors = ["memory_limiter", "batch"]
      exporters  = local.opentelemetry_collector_exporter_names
    }
  } : {}
  opentelemetry_collector_config = {
    receivers = local.opentelemetry_collector_receivers
    processors = {
      batch = {}
      memory_limiter = {
        check_interval  = "1s"
        limit_mib       = 256
        spike_limit_mib = 64
      }
    }
    exporters = local.opentelemetry_collector_exporters
    service = merge(
      {
        telemetry = {
          metrics = {
            address = "0.0.0.0:8888"
          }
        }
      },
      length(local.opentelemetry_collector_pipelines) > 0 ? {
        pipelines = local.opentelemetry_collector_pipelines
      } : {}
    )
  }
  extra_scrape_configs = concat(
    [local.honua_scrape_config],
    var.opentelemetry_collector_enabled ? [local.opentelemetry_collector_scrape_config] : []
  )

  prometheus_values = {
    alertmanager = {
      enabled = true
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
    }
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
    extraScrapeConfigs = yamlencode(local.extra_scrape_configs)
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

  opentelemetry_values = merge(
    {
      mode   = "deployment"
      config = local.opentelemetry_collector_config
      ports = {
        metrics = {
          enabled       = true
          containerPort = 8888
          servicePort   = 8888
          protocol      = "TCP"
        }
        otlp = {
          enabled       = var.opentelemetry_collector_enable_otlp_receiver
          containerPort = 4317
          servicePort   = 4317
          protocol      = "TCP"
        }
        otlp-http = {
          enabled       = var.opentelemetry_collector_enable_otlp_receiver
          containerPort = 4318
          servicePort   = 4318
          protocol      = "TCP"
        }
      }
      resources = {
        requests = {
          cpu    = "50m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "250m"
          memory = "256Mi"
        }
      }
    },
    var.opentelemetry_collector_values
  )
}

resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace
  }
}

check "opentelemetry_collector_exporters" {
  assert {
    condition     = !var.opentelemetry_collector_enabled || var.opentelemetry_collector_enable_debug_exporter || var.opentelemetry_collector_otlp_endpoint != ""
    error_message = "opentelemetry_collector_enabled requires opentelemetry_collector_otlp_endpoint or opentelemetry_collector_enable_debug_exporter."
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

resource "helm_release" "opentelemetry_collector" {
  count            = var.opentelemetry_collector_enabled ? 1 : 0
  name             = var.opentelemetry_release_name
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-collector"
  version          = var.opentelemetry_chart_version != "" ? var.opentelemetry_chart_version : null
  namespace        = var.namespace
  create_namespace = false
  timeout          = var.helm_timeout_seconds

  values = [yamlencode(local.opentelemetry_values)]

  depends_on = [kubernetes_namespace_v1.this]
}
