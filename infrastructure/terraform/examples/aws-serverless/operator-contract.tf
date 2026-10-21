# Customer-facing Lambda projection of honua.operator-contract/v2.
# All three contracts share canonical immutable identity and secret locators only.
# A complete identity is checked against the applied image and the exact published
# version behind the serving alias. These facts do not replace the provider-side
# observation, readiness, approval, or rollback qualification required for handoff.

data "aws_caller_identity" "operator_contract" {}

data "aws_partition" "operator_contract" {}

# Read the version named by Terraform's serving alias, not $LATEST. The AWS
# provider exports image_uri and role for this qualifier. A staged newer version
# cannot silently become the serving image in the contract.
data "aws_lambda_function" "operator_contract_alias" {
  count         = var.operator_contract_identity == null ? 0 : 1
  function_name = module.honua.lambda_function_name
  qualifier     = module.honua.lambda_alias_function_version
}

variable "operator_contract_identity" {
  description = "Optional immutable identity inputs for the honua.operator-contract/v2 output. Omit only for disposable, unqualified development plans; certified consumers must provide every required digest and backend/state lineage input."
  type = object({
    candidate_digest      = string
    manifest_digest       = optional(string)
    iac_revision          = string
    terraform_version     = string
    provider_lock_digest  = string
    image_digest          = string
    image_reference       = optional(string)
    backend_config_digest = optional(string)
    state_lineage         = optional(string)
    state_serial          = optional(number)
    workload_identity     = optional(string)
    artifacts = optional(list(object({
      name    = string
      kind    = string
      version = string
      digest  = string
    })), [])
  })
  default = null

  validation {
    condition = var.operator_contract_identity == null || (
      can(regex("^[0-9a-f]{64}$", try(var.operator_contract_identity.candidate_digest, ""))) &&
      can(regex("^([0-9a-f]{40}|[0-9a-f]{64})$", try(var.operator_contract_identity.iac_revision, ""))) &&
      try(trimspace(var.operator_contract_identity.terraform_version) != "", false) &&
      can(regex("^[0-9a-f]{64}$", try(var.operator_contract_identity.provider_lock_digest, ""))) &&
      can(regex("^sha256:[0-9a-f]{64}$", try(var.operator_contract_identity.image_digest, ""))) &&
      (try(var.operator_contract_identity.manifest_digest, null) == null || can(regex("^[0-9a-f]{64}$", var.operator_contract_identity.manifest_digest))) &&
      (try(var.operator_contract_identity.backend_config_digest, null) == null || can(regex("^[0-9a-f]{64}$", var.operator_contract_identity.backend_config_digest))) &&
      (try(var.operator_contract_identity.state_lineage, null) == null || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.operator_contract_identity.state_lineage))) &&
      (try(var.operator_contract_identity.state_serial, null) == null || try(var.operator_contract_identity.state_serial >= 0 && floor(var.operator_contract_identity.state_serial) == var.operator_contract_identity.state_serial, false))
    )
    error_message = "operator_contract_identity must use SHA-256 digests, a 40/64-character IaC revision, a sha256 image digest, a UUID state lineage, and a non-negative integer state serial when supplied."
  }

  validation {
    condition = var.operator_contract_identity == null ? true : (
      try(var.operator_contract_identity.image_reference, null) == null ? true :
      can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*(\\.[A-Za-z0-9._-]+)*(:[0-9]+)?(/[A-Za-z0-9._-]+)+@sha256:[0-9a-f]{64}$", var.operator_contract_identity.image_reference))
    )
    error_message = "operator_contract_identity.image_reference must be digest-pinned as registry/repository@sha256:<64 hex>; a mutable tag is not an immutable pin."
  }

  validation {
    condition = var.operator_contract_identity == null ? true : (
      try(var.operator_contract_identity.image_reference, null) == null ? true :
      try(endswith(var.operator_contract_identity.image_reference, "@${var.operator_contract_identity.image_digest}"), false)
    )
    error_message = "operator_contract_identity.image_reference must end with @<image_digest>; the reference and the digest must describe the same image."
  }

  validation {
    condition = var.operator_contract_identity == null ? true : alltrue([
      for artifact in try(var.operator_contract_identity.artifacts, []) :
      try(trimspace(artifact.name) != "", false) &&
      try(contains(["proxy", "cli", "mcp-server", "helm-chart", "package", "other"], artifact.kind), false) &&
      try(trimspace(artifact.version) != "", false) &&
      can(regex("^[0-9a-f]{64}$", artifact.digest))
    ])
    error_message = "Each operator_contract_identity.artifacts entry needs a name, a supported kind (proxy, cli, mcp-server, helm-chart, package, other), a version, and a 64-character SHA-256 digest."
  }
}

variable "operator_contract_validation" {
  description = "Optional validation-lane inputs projected into the honua.operator-contract/v2 validation contract. Defaults leave MCP validation disabled; declaring it requires the complete profile and tool roster."
  type = object({
    mcp_enabled        = optional(bool, false)
    mcp_profile        = optional(string)
    mcp_transport      = optional(string)
    mcp_path           = optional(string)
    mcp_required_tools = optional(list(string), [])
    seed_mode          = optional(string, "smoke")
    tenant_prefix      = optional(string, "honua-lambda")
    ttl_hours          = optional(number)
    cost_owner         = optional(string)
  })
  default = {}

  validation {
    condition     = contains(["none", "smoke", "full"], try(var.operator_contract_validation.seed_mode, "smoke"))
    error_message = "operator_contract_validation.seed_mode must be one of: none, smoke, full."
  }

  validation {
    condition     = try(trimspace(var.operator_contract_validation.tenant_prefix) != "", false)
    error_message = "operator_contract_validation.tenant_prefix must contain a non-whitespace character."
  }

  validation {
    condition = alltrue([
      for tool in var.operator_contract_validation.mcp_required_tools :
      try(trimspace(tool) != "", false)
    ])
    error_message = "Every operator_contract_validation.mcp_required_tools entry must contain a non-whitespace tool name."
  }

  validation {
    condition = try(var.operator_contract_validation.mcp_transport, null) == null ? true : (
      contains(["http", "stdio"], var.operator_contract_validation.mcp_transport)
    )
    error_message = "operator_contract_validation.mcp_transport must be http or stdio when set."
  }

  validation {
    condition = try(var.operator_contract_validation.mcp_enabled, false) == false ? true : (
      try(trimspace(var.operator_contract_validation.mcp_profile) != "", false) &&
      try(var.operator_contract_validation.mcp_transport, null) != null &&
      can(regex("^/", var.operator_contract_validation.mcp_path)) &&
      length(try(var.operator_contract_validation.mcp_required_tools, [])) > 0
    )
    error_message = "When operator_contract_validation.mcp_enabled is true, mcp_profile, mcp_transport, an absolute mcp_path, and a non-empty mcp_required_tools roster are all required."
  }

  validation {
    condition     = try(var.operator_contract_validation.ttl_hours, null) == null || try(var.operator_contract_validation.ttl_hours >= 0 && floor(var.operator_contract_validation.ttl_hours) == var.operator_contract_validation.ttl_hours, false)
    error_message = "operator_contract_validation.ttl_hours must be a non-negative integer when set."
  }
}

locals {
  operator_contract_schema_version = "honua.operator-contract/v2"

  operator_contract_root   = "infrastructure/terraform/examples/aws-serverless"
  operator_contract_module = "infrastructure/terraform/modules/aws-serverless"

  operator_contract_partition  = data.aws_partition.operator_contract.partition
  operator_contract_account_id = data.aws_caller_identity.operator_contract.account_id

  operator_contract_function_name = module.honua.lambda_function_name
  operator_contract_service_url   = module.honua.service_url
  operator_contract_public_url    = coalesce(module.honua.public_base_url, local.operator_contract_service_url)

  operator_contract_log_group = module.honua.operator_contract_facts.log_group

  operator_contract_ingress_dns_name = replace(local.operator_contract_service_url, "https://", "")

  operator_contract_identity_input = var.operator_contract_identity

  operator_contract_image_reference = try(local.operator_contract_identity_input.image_reference, null)
  operator_contract_image_digest    = try(local.operator_contract_identity_input.image_digest, null)

  operator_contract_artifacts = try(local.operator_contract_identity_input.artifacts, [])

  operator_contract_qualified = local.operator_contract_identity_input != null && alltrue([
    try(local.operator_contract_identity_input.candidate_digest, null) != null,
    try(local.operator_contract_identity_input.manifest_digest, null) != null,
    try(local.operator_contract_identity_input.iac_revision, null) != null,
    try(local.operator_contract_identity_input.terraform_version, null) != null,
    try(local.operator_contract_identity_input.provider_lock_digest, null) != null,
    local.operator_contract_image_reference != null,
    local.operator_contract_image_digest != null,
    try(local.operator_contract_identity_input.backend_config_digest, null) != null,
    try(local.operator_contract_identity_input.state_lineage, null) != null,
    try(local.operator_contract_identity_input.state_serial, null) != null,
    try(local.operator_contract_identity_input.workload_identity, null) != null,
  ])

  operator_contract_identity_base = {
    status                = local.operator_contract_qualified ? "qualified" : "unqualified"
    candidate_digest      = try(local.operator_contract_identity_input.candidate_digest, null)
    manifest_digest       = try(local.operator_contract_identity_input.manifest_digest, null)
    iac_revision          = try(local.operator_contract_identity_input.iac_revision, null)
    iac_root              = local.operator_contract_root
    module_source         = local.operator_contract_module
    terraform_version     = try(local.operator_contract_identity_input.terraform_version, null)
    provider_lock_digest  = try(local.operator_contract_identity_input.provider_lock_digest, null)
    image_reference       = local.operator_contract_image_reference
    image_digest          = local.operator_contract_image_digest
    backend_config_digest = try(local.operator_contract_identity_input.backend_config_digest, null)
    state_lineage         = try(local.operator_contract_identity_input.state_lineage, null)
    state_serial          = try(local.operator_contract_identity_input.state_serial, null)
    workload_identity     = try(local.operator_contract_identity_input.workload_identity, null)
    artifacts             = local.operator_contract_artifacts
    platform = {
      provider   = "aws"
      partition  = local.operator_contract_partition
      account_id = local.operator_contract_account_id
      region     = var.region
    }
  }

  operator_contract_mcp_enabled = try(var.operator_contract_validation.mcp_enabled, false)
  operator_contract_mcp_path    = local.operator_contract_mcp_enabled ? var.operator_contract_validation.mcp_path : null
  operator_contract_ttl_hours   = try(var.operator_contract_validation.ttl_hours, null)

  operator_contract_redis_secret_arn = nonsensitive(module.honua.redis_connection_secret_arn)
  operator_contract_cache_enabled    = local.operator_contract_redis_secret_arn != null

  operator_contract_pro_license_secret_arn = module.honua.pro_license_secret_arn

  operator_contract_database_managed = module.honua.operator_contract_facts.database_managed

  operator_contract_deployment_secret_refs = { for name, arn in {
    admin_password                   = module.honua.admin_password_secret_arn
    connection_encryption_master_key = module.honua.master_key_secret_arn
    db_connection                    = module.honua.runtime_db_connection_secret_arn
    redis_connection                 = local.operator_contract_redis_secret_arn
    operation_key_ring_certificate   = module.honua.operation_key_ring_certificate_secret_arn
    audit_chain_key                  = module.honua.audit_chain_key_secret_arn
    pro_license                      = local.operator_contract_pro_license_secret_arn
  } : name => arn if arn != null }

  operator_contract_secret_registry = { for name, ref in {
    admin_password = {
      kind        = "admin_password"
      provider    = "aws-secretsmanager"
      id          = module.honua.admin_password_secret_arn
      kms_key_ref = null
      managed_by  = "honua-iac"
    }
    connection_encryption_master_key = {
      kind        = "connection_encryption_master_key"
      provider    = "aws-secretsmanager"
      id          = module.honua.master_key_secret_arn
      kms_key_ref = null
      managed_by  = "honua-iac"
    }
    operation_key_ring_certificate = module.honua.operation_key_ring_certificate_secret_arn == null ? null : {
      kind        = "operation_key_ring_certificate"
      provider    = "aws-secretsmanager"
      id          = module.honua.operation_key_ring_certificate_secret_arn
      kms_key_ref = var.operation_key_ring_certificate_secret_kms_key_arn != "" ? var.operation_key_ring_certificate_secret_kms_key_arn : null
      managed_by  = "operator"
    }
    audit_chain_key = module.honua.audit_chain_key_secret_arn == null ? null : {
      kind        = "audit_chain_key"
      provider    = "aws-secretsmanager"
      id          = module.honua.audit_chain_key_secret_arn
      kms_key_ref = var.audit_chain_key_secret_kms_key_arn != "" ? var.audit_chain_key_secret_kms_key_arn : null
      managed_by  = "operator"
    }
    db_connection = {
      kind        = "db_connection"
      provider    = "aws-secretsmanager"
      id          = module.honua.runtime_db_connection_secret_arn
      kms_key_ref = null
      managed_by  = "honua-iac"
    }
    redis_connection = local.operator_contract_redis_secret_arn == null ? null : {
      kind        = "redis_connection"
      provider    = "aws-secretsmanager"
      id          = local.operator_contract_redis_secret_arn
      kms_key_ref = null
      managed_by  = "honua-iac"
    }
    pro_license = local.operator_contract_pro_license_secret_arn == null ? null : {
      kind        = "other"
      provider    = "aws-secretsmanager"
      id          = local.operator_contract_pro_license_secret_arn
      kms_key_ref = null
      managed_by  = module.honua.pro_license_secret_managed_by_terraform ? "honua-iac" : "operator"
    }
  } : name => ref if ref != null }

  operator_contract_deployment_base = {
    schema_version = local.operator_contract_schema_version
    kind           = "deployment"
    identity       = local.operator_contract_identity_base
    stack = {
      id          = "aws-lambda"
      platform    = "aws"
      runtime     = "lambda"
      environment = var.environment
      region      = var.region
      account_id  = local.operator_contract_account_id
      name_prefix = var.name_prefix
    }
    endpoints = {
      public_base_url  = local.operator_contract_public_url
      readiness_path   = "/healthz/ready"
      admin_base_path  = "/api/v1/admin"
      protocol_path    = "/v1"
      mcp_path         = local.operator_contract_mcp_path
      ingress_dns_name = local.operator_contract_ingress_dns_name
      custom_domain    = module.honua.custom_domain_name
    }
    workload = {
      kind        = module.honua.control_plane_target_kind
      name        = local.operator_contract_function_name
      resource_id = module.honua.lambda_alias_arn
      # v2 compatibility grouping only: Lambda has no cluster. cluster_id is null.
      cluster_name     = module.honua.operator_contract_facts.resource_group
      cluster_id       = null
      cpu_architecture = one(module.honua.lambda_architectures)
      # Zero means no standing instance count is declared, not a concurrency limit.
      desired_count = 0
      identity      = try(local.operator_contract_identity_input.workload_identity, null)
    }
    rollout = {
      backend_name     = module.honua.control_plane_backend_name
      target_kind      = module.honua.control_plane_target_kind
      target_id        = module.honua.control_plane_target_id
      target_name      = module.honua.control_plane_target_name
      target_resource  = module.honua.control_plane_target_resource_id
      current_revision = module.honua.control_plane_current_revision
      desired_revision = module.honua.control_plane_desired_revision
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
        kind       = module.honua.operator_contract_facts.database_kind
        managed    = local.operator_contract_database_managed
        endpoint   = module.honua.operator_contract_facts.database_endpoint
        secret_ref = module.honua.runtime_db_connection_secret_arn
      }
      cache = {
        kind       = module.honua.operator_contract_facts.cache_kind
        enabled    = local.operator_contract_cache_enabled
        secret_ref = local.operator_contract_redis_secret_arn
      }
      ingress = {
        kind            = "aws-apigatewayv2-http"
        endpoint        = local.operator_contract_service_url
        certificate_ref = module.honua.custom_domain_certificate_arn
        waf_ref         = null
      }
      object_storage = module.honua.operator_contract_facts.object_storage
    }
    secret_refs = local.operator_contract_deployment_secret_refs
  }

  operator_contract_validation_base = {
    schema_version = local.operator_contract_schema_version
    kind           = "validation"
    identity       = local.operator_contract_identity_base
    platform = {
      name = "aws-lambda"
      capabilities = {
        deploy_plan   = true
        mutation      = true
        scale_check   = false
        backup_drill  = local.operator_contract_database_managed
        idempotency   = true
        http_protocol = true
        mcp           = local.operator_contract_mcp_enabled
      }
    }
    tests = {
      readiness_url = "${local.operator_contract_public_url}/healthz/ready"
      admin_url     = "${local.operator_contract_public_url}/api/v1/admin"
      protocol_url  = "${local.operator_contract_public_url}/v1"
      mcp_url       = local.operator_contract_mcp_enabled ? "${local.operator_contract_public_url}${local.operator_contract_mcp_path}" : null
    }
    mcp = {
      enabled        = local.operator_contract_mcp_enabled
      profile        = local.operator_contract_mcp_enabled ? var.operator_contract_validation.mcp_profile : null
      transport      = local.operator_contract_mcp_enabled ? var.operator_contract_validation.mcp_transport : null
      required_tools = local.operator_contract_mcp_enabled ? var.operator_contract_validation.mcp_required_tools : []
    }
    test_data = {
      seed_mode            = try(var.operator_contract_validation.seed_mode, "smoke")
      tenant_prefix        = try(var.operator_contract_validation.tenant_prefix, "honua-lambda")
      reuse_data_stack     = !local.operator_contract_database_managed
      admin_credential_ref = module.honua.admin_password_secret_arn
    }
    artifacts = {
      terraform_root  = local.operator_contract_root
      module_source   = local.operator_contract_module
      image_reference = local.operator_contract_image_reference
      image_digest    = local.operator_contract_image_digest
      pins            = local.operator_contract_artifacts
    }
    lifecycle = {
      reuse_data_stack = !local.operator_contract_database_managed
      destroy_mode     = var.environment == "prod" ? "protected" : "ephemeral"
      ttl_hours        = local.operator_contract_ttl_hours
    }
    selectors = {
      account_id  = local.operator_contract_account_id
      region      = var.region
      cluster_arn = null
      service_arn = null
      log_group   = local.operator_contract_log_group
      tag_filters = module.honua.operator_contract_facts.tags
    }
  }

  operator_contract_operations_base = {
    schema_version = local.operator_contract_schema_version
    kind           = "operations"
    identity       = local.operator_contract_identity_base
    observability = {
      telemetry_policy      = module.honua.control_plane_telemetry_policy
      prometheus_job        = null
      prometheus_canary_job = null
      log_group             = local.operator_contract_log_group
      metrics_namespace     = module.honua.operator_contract_facts.metrics_namespace
    }
    secrets = {
      provider   = "aws-secretsmanager"
      references = local.operator_contract_secret_registry
    }
    scaling = {
      deployment_mode = "Serverless"
      # v2 requires integer counts. These mean no configured standing capacity;
      # Lambda concurrency is not represented by ECS-style instance counts.
      desired_count    = 0
      max_capacity     = 0
      cpu_architecture = one(module.honua.lambda_architectures)
    }
    resilience = {
      ingress_deletion_protection = false
      ingress_access_logs_enabled = true
      database_managed            = local.operator_contract_database_managed
      cache_enabled               = local.operator_contract_cache_enabled
    }
    grouping = {
      resource_group = module.honua.operator_contract_facts.resource_group
      name_prefix    = var.name_prefix
      tags           = module.honua.operator_contract_facts.tags
    }
    cost = {
      owner     = try(var.operator_contract_validation.cost_owner, null)
      ephemeral = var.environment != "prod"
      ttl_hours = local.operator_contract_ttl_hours
    }
    state = {
      terraform_root        = local.operator_contract_root
      backend_config_digest = try(local.operator_contract_identity_input.backend_config_digest, null)
      lineage               = try(local.operator_contract_identity_input.state_lineage, null)
      serial                = try(local.operator_contract_identity_input.state_serial, null)
    }
  }

  operator_contract_digest_input = {
    schema_version      = local.operator_contract_schema_version
    deployment_contract = local.operator_contract_deployment_base
    validation_contract = local.operator_contract_validation_base
    operations_contract = local.operator_contract_operations_base
  }

  operator_contract_digest = sha256(jsonencode(local.operator_contract_digest_input))

  operator_contract_identity_final = merge(
    local.operator_contract_identity_base,
    { contract_digest = local.operator_contract_digest }
  )

  deployment_contract = merge(
    local.operator_contract_deployment_base,
    { identity = local.operator_contract_identity_final }
  )

  validation_contract = merge(
    local.operator_contract_validation_base,
    { identity = local.operator_contract_identity_final }
  )

  operations_contract = merge(
    local.operator_contract_operations_base,
    { identity = local.operator_contract_identity_final }
  )

  operator_contract = {
    schema_version      = local.operator_contract_schema_version
    deployment_contract = local.deployment_contract
    validation_contract = local.validation_contract
    operations_contract = local.operations_contract
  }
}

output "deployment_contract" {
  description = "Canonical honua.operator-contract/v2 deployment contract for the AWS Lambda root. Authoritative handoff for honua-devops install."
  value       = local.deployment_contract

  # Dependency settings belong to the configured function. A previous alias
  # version may carry older environment/secret references even with the same
  # image, so it cannot qualify this complete deployment projection.
  precondition {
    condition = local.operator_contract_identity_input == null ? true : (
      module.honua.lambda_alias_function_version == module.honua.lambda_function_version
    )
    error_message = "The serving alias must select the configured published function version before this operator contract can carry immutable deployment identity."
  }

  precondition {
    condition = local.operator_contract_identity_input == null ? true : (
      local.operator_contract_image_reference == null ? true :
      data.aws_lambda_function.operator_contract_alias[0].image_uri == local.operator_contract_image_reference
    )
    error_message = "The serving Lambda alias version does not use operator_contract_identity.image_reference. Complete the alias deployment or restore the matching configuration before claiming this image."
  }

  precondition {
    condition = try(local.operator_contract_identity_input.workload_identity, null) == null ? true : (
      data.aws_lambda_function.operator_contract_alias[0].role == local.operator_contract_identity_input.workload_identity &&
      module.honua.operator_contract_facts.workload_identity == local.operator_contract_identity_input.workload_identity
    )
    error_message = "operator_contract_identity.workload_identity must equal the execution role of both the configured Lambda and its serving alias version."
  }

  precondition {
    condition     = local.operator_contract_image_reference == null || local.install_image == local.operator_contract_image_reference
    error_message = "The deployed image (${local.install_image}) does not match operator_contract_identity.image_reference. Deploy the digest-pinned reference; Terraform will not convert a mutable tag into an immutable claim."
  }

  precondition {
    condition     = local.operator_contract_identity_input == null || can(regex("@sha256:[0-9a-f]{64}$", local.install_image))
    error_message = "The deployed image (${local.install_image}) is not digest-pinned. An operator contract carrying immutable identity requires an image reference of the form registry/repository@sha256:<64 hex>."
  }
}

output "validation_contract" {
  description = "Canonical honua.operator-contract/v2 validation contract for the AWS Lambda root. Authoritative handoff for verification, smoke, and teardown lanes."
  value       = local.validation_contract
}

output "operations_contract" {
  description = "Canonical honua.operator-contract/v2 operations contract for the AWS Lambda root. Authoritative handoff for day-2 operations and runtime configuration."
  value       = local.operations_contract
}

output "operator_contract" {
  description = "Convenience envelope carrying all three honua.operator-contract/v2 contracts. Non-normative: the three contracts are the authoritative outputs."
  value       = local.operator_contract
}

output "operator_contract_digest" {
  description = "SHA-256 over the canonical bytes of the operator contract digest input. Identical to identity.contract_digest in all three contracts."
  value       = local.operator_contract_digest
}

output "operator_contract_status" {
  description = "qualified when every immutable pin required for release use is present; unqualified otherwise. Certified consumers must reject unqualified contracts."
  value       = local.operator_contract_identity_base.status
}
