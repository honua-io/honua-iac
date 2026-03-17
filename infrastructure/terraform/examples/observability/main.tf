provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

module "observability" {
  source = "../../modules/observability-stack"

  namespace            = var.namespace
  honua_metrics_target = var.honua_metrics_target

  grafana_ingress_enabled = var.grafana_ingress_host != ""
  grafana_ingress_host    = var.grafana_ingress_host
}

locals {
  deployment_contract = {
    schema_version = "v1"
    stack = {
      id          = "observability"
      platform    = "kubernetes-observability"
      runtime     = "observability"
      environment = "shared"
      region      = null
    }
    endpoints = {
      public_base_url   = var.grafana_ingress_host != "" ? module.observability.grafana_url : null
      readiness_url     = null
      admin_url         = null
      protocol_url      = null
      internal_base_url = module.observability.prometheus_url
    }
    workload = {
      kind        = "KubernetesObservability"
      name        = module.observability.prometheus_release
      resource_id = null
      grafana     = module.observability.grafana_release
    }
    rollout = {
      backend_name       = null
      target_id          = null
      target_name        = null
      target_resource_id = null
      current_revision   = null
      desired_revision   = null
    }
    dependencies = {
      metrics = {
        kind     = "prometheus-scrape"
        target   = var.honua_metrics_target
        selector = module.observability.honua_prometheus_selector
      }
    }
  }

  validation_contract = {
    schema_version = "v1"
    platform = {
      name = "kubernetes-observability"
      capabilities = {
        deploy_plan     = false
        mutation        = false
        scale_check     = false
        backup_drill    = false
        idempotency     = true
        protocol_checks = false
      }
    }
    tests = {
      base_url      = var.grafana_ingress_host != "" ? module.observability.grafana_url : null
      readiness_url = null
      admin_url     = null
      protocol_url  = null
    }
    artifacts = {
      terraform_root      = path.cwd
      namespace           = var.namespace
      prometheus_release  = module.observability.prometheus_release
      grafana_release     = module.observability.grafana_release
      dashboard_configmap = module.observability.dashboard_configmap_name
    }
    lifecycle = {
      reuse_data_stack = false
      destroy_mode     = "explicit"
    }
  }

  operations_contract = {
    schema_version = "v1"
    observability = {
      telemetry_policy      = "prometheus-grafana"
      prometheus_job        = module.observability.honua_prometheus_job_name
      prometheus_canary_job = null
      prometheus_url        = module.observability.prometheus_url
      grafana_url           = module.observability.grafana_url
    }
    secrets = {
      secret_store = {
        kind = "kubernetes-secret"
        id   = module.observability.grafana_admin_secret_name
      }
      admin_password_secret   = module.observability.grafana_admin_secret_name
      db_connection_secret    = null
      redis_connection_secret = null
    }
    grouping = {
      environment    = "shared"
      name_prefix    = "observability"
      resource_group = null
      namespace      = var.namespace
      tags           = {}
    }
  }
}

output "deployment_contract" {
  description = "Stable deployment contract for validation and operator automation."
  value       = local.deployment_contract
  sensitive   = true
}

output "validation_contract" {
  description = "Stable validation contract for scenario orchestration."
  value       = local.validation_contract
  sensitive   = true
}

output "operations_contract" {
  description = "Stable operations contract for day-2 metadata and secret references."
  value       = local.operations_contract
  sensitive   = true
}

output "prometheus_url" {
  value = module.observability.prometheus_url
}

output "honua_prometheus_job_name" {
  value = module.observability.honua_prometheus_job_name
}

output "honua_prometheus_selector" {
  value = module.observability.honua_prometheus_selector
}

output "grafana_url" {
  value = module.observability.grafana_url
}

output "grafana_admin_secret_name" {
  value = module.observability.grafana_admin_secret_name
}
