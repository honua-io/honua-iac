# Canonical v2 contract is a configured install projection. Provider/runtime
# observation, serving revision and caller authorization belong to DevOps.
locals {
  contract_root           = "infrastructure/terraform/examples/aws-eks-native"
  contract_schema_version = "honua.operator-contract/v2"
  # The exact executor reads the *post-apply* state lineage and serial and
  # seals them in its execution receipt. A Terraform output cannot certify its
  # own eventual state serial, so this configured contract never self-qualifies.
  contract_identity_base = {
    status                = "unqualified"
    candidate_digest      = null
    manifest_digest       = null
    iac_revision          = null
    iac_root              = local.contract_root
    module_source         = local.contract_root
    terraform_version     = null
    provider_lock_digest  = null
    image_reference       = var.image_reference
    image_digest          = local.server_digest
    backend_config_digest = null
    state_lineage         = null
    state_serial          = null
    workload_identity     = var.server_role_arn
    artifacts             = []
    platform = {
      provider   = "aws"
      partition  = data.aws_partition.current.partition
      account_id = data.aws_caller_identity.current.account_id
      region     = var.region
    }
  }

  contract_secret_refs = merge({
    admin_password                   = var.admin_password_secret_arn
    db_connection                    = var.db_connection_secret_arn
    connection_encryption_master_key = var.master_key_secret_arn
    }, var.redis_connection_secret_arn == "" ? {} : {
    redis_connection = var.redis_connection_secret_arn
    }, var.operation_key_ring_certificate_secret_arn == "" ? {} : {
    operation_key_ring_certificate = var.operation_key_ring_certificate_secret_arn
    }, var.audit_chain_key_secret_arn == "" ? {} : {
    audit_chain_key = var.audit_chain_key_secret_arn
  })

  contract_secret_registry = {
    for name, arn in local.contract_secret_refs : name => {
      kind       = name
      provider   = "aws-secretsmanager"
      id         = arn
      managed_by = contains(["audit_chain_key", "operation_key_ring_certificate"], name) ? "operator" : "honua-iac"
    }
  }

  contract_deployment_base = {
    schema_version = local.contract_schema_version
    kind           = "deployment"
    identity       = local.contract_identity_base
    stack = {
      id          = "aws-eks-native"
      platform    = "aws"
      runtime     = "eks"
      environment = var.environment
      region      = var.region
      account_id  = data.aws_caller_identity.current.account_id
      name_prefix = var.target_id
    }
    endpoints = {
      public_base_url  = local.public_url
      readiness_path   = "/healthz/ready"
      admin_base_path  = "/api/v1/admin"
      protocol_path    = "/v1"
      mcp_path         = var.mcp_validation.enabled ? var.mcp_validation.path : null
      ingress_dns_name = local.lb_hostname
      custom_domain    = var.public_hostname
    }
    workload = {
      kind             = "Kubernetes"
      name             = kubernetes_deployment_v1.honua.metadata[0].name
      resource_id      = null
      cluster_name     = var.cluster_name
      cluster_id       = data.aws_eks_cluster.selected.arn
      cpu_architecture = "unspecified"
      desired_count    = var.replicas
      identity         = var.server_role_arn
    }
    rollout = {
      backend_name     = "honua-kubernetes-deployment"
      target_kind      = "Kubernetes"
      target_id        = var.target_id
      target_name      = kubernetes_deployment_v1.honua.metadata[0].name
      target_resource  = data.aws_eks_cluster.selected.arn
      current_revision = null
      desired_revision = null
      canary = {
        enabled                  = false
        service_name             = null
        target_group_arn         = null
        weight_percentage        = 0
        verification_header_name = null
      }
    }
    dependencies = {
      database = {
        kind       = "aws-rds-postgres"
        managed    = false
        endpoint   = null
        secret_ref = var.db_connection_secret_arn
      }
      cache = {
        kind       = "aws-elasticache-redis"
        enabled    = var.redis_connection_secret_arn != ""
        secret_ref = var.redis_connection_secret_arn == "" ? null : var.redis_connection_secret_arn
      }
      ingress = {
        kind            = "aws-nlb"
        endpoint        = local.public_url
        certificate_ref = var.certificate_arn
        waf_ref         = null
      }
      object_storage = {
        kind    = null
        enabled = false
        bucket  = null
        prefix  = null
      }
    }
    secret_refs = local.contract_secret_refs
  }

  contract_validation_base = {
    schema_version = local.contract_schema_version
    kind           = "validation"
    identity       = local.contract_identity_base
    platform = {
      name = "aws-eks"
      capabilities = {
        deploy_plan   = true
        mutation      = true
        scale_check   = false
        backup_drill  = false
        idempotency   = true
        http_protocol = true
        mcp           = var.mcp_validation.enabled
      }
    }
    tests = {
      readiness_url = "${local.public_url}/healthz/ready"
      admin_url     = "${local.public_url}/api/v1/admin"
      protocol_url  = "${local.public_url}/v1"
      mcp_url       = var.mcp_validation.enabled ? "${local.public_url}${var.mcp_validation.path}" : null
    }
    mcp = {
      enabled        = var.mcp_validation.enabled
      profile        = var.mcp_validation.enabled ? var.mcp_validation.profile : null
      transport      = var.mcp_validation.enabled ? var.mcp_validation.transport : null
      required_tools = var.mcp_validation.enabled ? var.mcp_validation.required_tools : []
    }
    test_data = {
      seed_mode            = "none"
      tenant_prefix        = var.tenant_id
      reuse_data_stack     = true
      admin_credential_ref = var.admin_password_secret_arn
    }
    artifacts = {
      terraform_root  = local.contract_root
      module_source   = local.contract_root
      image_reference = var.image_reference
      image_digest    = local.server_digest
      pins            = []
    }
    lifecycle = {
      reuse_data_stack = true
      destroy_mode     = var.environment == "prod" ? "protected" : "manual"
      ttl_hours        = null
    }
    selectors = {
      account_id  = data.aws_caller_identity.current.account_id
      region      = var.region
      cluster_arn = data.aws_eks_cluster.selected.arn
      service_arn = null
      log_group   = null
      tag_filters = {}
    }
  }

  contract_operations_base = {
    schema_version = local.contract_schema_version
    kind           = "operations"
    identity       = local.contract_identity_base
    observability = {
      telemetry_policy      = "kubernetes-honua-http"
      prometheus_job        = null
      prometheus_canary_job = null
      log_group             = null
      metrics_namespace     = null
    }
    secrets = {
      provider   = "aws-secretsmanager"
      references = local.contract_secret_registry
    }
    scaling = {
      deployment_mode  = "KubernetesDeployment"
      desired_count    = var.replicas
      max_capacity     = var.replicas
      cpu_architecture = "unspecified"
    }
    resilience = {
      ingress_deletion_protection = false
      ingress_access_logs_enabled = false
      database_managed            = false
      cache_enabled               = var.redis_connection_secret_arn != ""
    }
    grouping = {
      resource_group = var.cluster_name
      name_prefix    = var.target_id
      tags           = {}
    }
    cost = {
      owner     = null
      ephemeral = var.environment != "prod"
      ttl_hours = null
    }
    state = {
      terraform_root        = local.contract_root
      backend_config_digest = null
      lineage               = null
      serial                = null
    }
  }

  contract_digest_input = {
    schema_version      = local.contract_schema_version
    deployment_contract = local.contract_deployment_base
    validation_contract = local.contract_validation_base
    operations_contract = local.contract_operations_base
  }
  contract_digest = sha256(jsonencode(local.contract_digest_input))
  contract_identity_final = merge(local.contract_identity_base, {
    contract_digest = local.contract_digest
  })
  deployment_contract = merge(local.contract_deployment_base, {
    identity = local.contract_identity_final
  })
  validation_contract = merge(local.contract_validation_base, {
    identity = local.contract_identity_final
  })
  operations_contract = merge(local.contract_operations_base, {
    identity = local.contract_identity_final
  })
}

output "deployment_contract" {
  description = "honua.operator-contract/v2 deployment contract for the configured native EKS install."
  value       = local.deployment_contract
}

output "validation_contract" {
  value = local.validation_contract
}

output "operations_contract" {
  value = local.operations_contract
}

output "operator_contract" {
  value = {
    schema_version      = local.contract_schema_version
    deployment_contract = local.deployment_contract
    validation_contract = local.validation_contract
    operations_contract = local.operations_contract
  }
}

output "operator_contract_digest" {
  value = local.contract_digest
}

output "operator_contract_status" {
  value = local.contract_identity_base.status
}
