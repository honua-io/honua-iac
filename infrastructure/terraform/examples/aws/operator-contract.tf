# Canonical honua.operator-contract/v1 producer for the AWS ECS small root.
#
# Schema: infrastructure/terraform/contracts/operator-contract.v1.schema.json
# Spec:   docs/operator-contract.md
#
# Rules this file exists to hold:
#
#   1. Secretless. Every credential appears as a Secrets Manager / SSM / KMS
#      reference. No password, connection string, token, header value, or
#      rendered sensitive environment value is ever projected.
#   2. Terraform projects immutable identity; it never manufactures it. The
#      release manifest supplies the candidate digest, manifest digest, IaC
#      revision, provider-lock digest, and image digest. This root refuses to
#      resolve a mutable tag into a digest claim and refuses to guess a Git
#      revision.
#   3. All three contracts carry a byte-identical identity block, including a
#      contract digest computed over canonical bytes (see the spec) so a
#      consumer can detect substituted contract bytes.
#   4. Without a complete identity input the contract is emitted with
#      status = "unqualified". Certified consumers must reject it.

data "aws_caller_identity" "operator_contract" {}

data "aws_partition" "operator_contract" {}

variable "operator_contract_validation" {
  description = "Optional validation-lane inputs projected into the honua.operator-contract/v1 validation contract. Defaults describe a smoke-seeded ephemeral cell with MCP disabled."
  type = object({
    mcp_enabled        = optional(bool, false)
    mcp_profile        = optional(string)
    mcp_transport      = optional(string)
    mcp_path           = optional(string)
    mcp_required_tools = optional(list(string), [])
    seed_mode          = optional(string, "smoke")
    tenant_prefix      = optional(string, "honua-it")
    ttl_hours          = optional(number)
    cost_owner         = optional(string)
  })
  default = {}

  validation {
    condition     = contains(["none", "smoke", "full"], try(var.operator_contract_validation.seed_mode, "smoke"))
    error_message = "operator_contract_validation.seed_mode must be one of: none, smoke, full."
  }

  validation {
    condition = try(var.operator_contract_validation.mcp_transport, null) == null ? true : (
      contains(["http", "stdio"], var.operator_contract_validation.mcp_transport)
    )
    error_message = "operator_contract_validation.mcp_transport must be http or stdio when set."
  }

  # A validation lane that claims MCP support has to name the profile, the
  # transport, the mount path, and the tool roster it will be asserted against.
  # A half-declared MCP capability is worse than a disabled one.
  #
  # HCL evaluates both operands of || and &&, so this is written as a
  # conditional: with MCP disabled the attributes below are legitimately null
  # and must not be handed to trimspace() or regex().
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
    condition     = try(var.operator_contract_validation.ttl_hours, null) == null || try(var.operator_contract_validation.ttl_hours >= 0, false)
    error_message = "operator_contract_validation.ttl_hours must be non-negative when set."
  }
}

locals {
  operator_contract_schema_version = "honua.operator-contract/v1"

  operator_contract_root   = "infrastructure/terraform/examples/aws"
  operator_contract_module = "infrastructure/terraform/modules/aws-ecs"

  operator_contract_partition  = data.aws_partition.operator_contract.partition
  operator_contract_account_id = data.aws_caller_identity.operator_contract.account_id

  # Deterministic module naming rule (modules/aws-ecs): resources are named from
  # "<name_prefix>-<environment>". Reconstructing ARNs from partition, region,
  # and account is a naming derivation, not an identity claim.
  operator_contract_base_name    = "${var.name_prefix}-${var.environment}"
  operator_contract_cluster_name = module.honua.ecs_cluster_name
  operator_contract_service_name = module.honua.ecs_service_name
  operator_contract_log_group    = "/honua/${local.operator_contract_base_name}"

  operator_contract_cluster_arn = "arn:${local.operator_contract_partition}:ecs:${var.region}:${local.operator_contract_account_id}:cluster/${local.operator_contract_cluster_name}"
  operator_contract_service_arn = "arn:${local.operator_contract_partition}:ecs:${var.region}:${local.operator_contract_account_id}:service/${local.operator_contract_cluster_name}/${local.operator_contract_service_name}"

  operator_contract_identity_input = var.operator_contract_identity

  # image_reference is the authoritative digest-pinned reference. When the
  # caller supplies only a digest we do not synthesize a repository for it.
  operator_contract_image_reference = try(local.operator_contract_identity_input.image_reference, null)
  operator_contract_image_digest    = try(local.operator_contract_identity_input.image_digest, null)

  operator_contract_artifacts = try(local.operator_contract_identity_input.artifacts, [])

  # "qualified" means every pin a release deployment needs is present. Missing
  # any one of them downgrades the whole contract; there is no partial credit.
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

  # Identity without the self-referential contract_digest field. This is the
  # block that goes into the digest input; the digest is merged back in below.
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

  operator_contract_object_storage_enabled = var.file_storage_provider == "AwsS3"

  operator_contract_mcp_enabled = try(var.operator_contract_validation.mcp_enabled, false)
  operator_contract_mcp_path    = local.operator_contract_mcp_enabled ? var.operator_contract_validation.mcp_path : null
  operator_contract_ttl_hours   = try(var.operator_contract_validation.ttl_hours, null)

  operator_contract_service_url = module.honua.service_url

  # Secret references only. Nulls are dropped so a consumer never has to decide
  # what an absent-but-present key means.
  operator_contract_deployment_secret_refs = { for name, arn in {
    admin_password                   = module.honua.admin_password_secret_arn
    connection_encryption_master_key = module.honua.connection_encryption_master_key_secret_arn
    db_connection                    = module.honua.db_connection_secret_arn
    redis_connection                 = nonsensitive(module.honua.redis_connection_secret_arn)
    ai_provider_api_key              = var.ai_provider_secret_arn != "" ? var.ai_provider_secret_arn : null
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
      id          = module.honua.connection_encryption_master_key_secret_arn
      kms_key_ref = null
      managed_by  = "honua-iac"
    }
    db_connection = {
      kind        = "db_connection"
      provider    = "aws-secretsmanager"
      id          = module.honua.db_connection_secret_arn
      kms_key_ref = null
      managed_by  = "honua-iac"
    }
    redis_connection = nonsensitive(module.honua.redis_connection_secret_arn) == null ? null : {
      kind        = "redis_connection"
      provider    = "aws-secretsmanager"
      id          = nonsensitive(module.honua.redis_connection_secret_arn)
      kms_key_ref = null
      managed_by  = "honua-iac"
    }
    ai_provider_api_key = var.ai_provider_secret_arn == "" ? null : {
      kind        = "ai_provider_api_key"
      provider    = "aws-secretsmanager"
      id          = var.ai_provider_secret_arn
      kms_key_ref = var.ai_provider_secret_kms_key_arn != "" ? var.ai_provider_secret_kms_key_arn : null
      managed_by  = "operator"
    }
  } : name => ref if ref != null }

  operator_contract_deployment_base = {
    schema_version = local.operator_contract_schema_version
    kind           = "deployment"
    identity       = local.operator_contract_identity_base
    stack = {
      id          = "aws-ecs"
      platform    = "aws"
      runtime     = "ecs-fargate"
      environment = var.environment
      region      = var.region
      account_id  = local.operator_contract_account_id
      name_prefix = var.name_prefix
    }
    endpoints = {
      public_base_url  = local.operator_contract_service_url
      readiness_path   = "/healthz/ready"
      admin_base_path  = "/api/v1/admin"
      protocol_path    = "/v1"
      mcp_path         = local.operator_contract_mcp_path
      ingress_dns_name = module.honua.alb_dns_name
      custom_domain    = module.honua.service_domain_name
    }
    workload = {
      kind             = module.honua.control_plane_target_kind
      name             = local.operator_contract_service_name
      resource_id      = local.operator_contract_service_arn
      cluster_name     = local.operator_contract_cluster_name
      cluster_id       = local.operator_contract_cluster_arn
      cpu_architecture = var.task_cpu_architecture
      desired_count    = var.desired_count
      identity         = try(local.operator_contract_identity_input.workload_identity, null)
    }
    rollout = {
      backend_name    = module.honua.control_plane_backend_name
      target_kind     = module.honua.control_plane_target_kind
      target_id       = local.operator_contract_service_name
      target_name     = local.operator_contract_service_name
      target_resource = local.operator_contract_cluster_arn
      # Revisions are observed by the rollout controller after apply. Terraform
      # does not claim a revision it cannot prove.
      current_revision = null
      desired_revision = null
      canary = {
        enabled                  = module.honua.canary_enabled
        service_name             = module.honua.canary_ecs_service_name
        target_group_arn         = module.honua.canary_target_group_arn
        weight_percentage        = module.honua.canary_weight_percentage
        verification_header_name = module.honua.canary_verification_header_name
      }
    }
    dependencies = {
      database = {
        kind       = "aws-rds-postgres"
        managed    = var.existing_db_endpoint == ""
        endpoint   = nonsensitive(module.honua.db_endpoint)
        secret_ref = module.honua.db_connection_secret_arn
      }
      cache = {
        kind       = "aws-elasticache-redis"
        enabled    = var.redis_enabled
        secret_ref = nonsensitive(module.honua.redis_connection_secret_arn)
      }
      ingress = {
        kind            = "aws-alb"
        endpoint        = local.operator_contract_service_url
        certificate_ref = module.honua.certificate_arn
        waf_ref         = var.waf_web_acl_arn != "" ? var.waf_web_acl_arn : null
      }
      object_storage = {
        kind    = local.operator_contract_object_storage_enabled ? "aws-s3" : null
        enabled = local.operator_contract_object_storage_enabled
        bucket  = local.operator_contract_object_storage_enabled && var.file_storage_aws_s3_bucket_name != "" ? var.file_storage_aws_s3_bucket_name : null
        prefix  = local.operator_contract_object_storage_enabled && var.file_storage_aws_s3_key_prefix != "" ? var.file_storage_aws_s3_key_prefix : null
      }
    }
    secret_refs = local.operator_contract_deployment_secret_refs
  }

  operator_contract_validation_base = {
    schema_version = local.operator_contract_schema_version
    kind           = "validation"
    identity       = local.operator_contract_identity_base
    platform = {
      name = "aws-ecs"
      capabilities = {
        deploy_plan   = true
        mutation      = true
        scale_check   = var.deployment_mode == "MultiNode"
        backup_drill  = var.existing_db_endpoint == ""
        idempotency   = true
        http_protocol = true
        mcp           = local.operator_contract_mcp_enabled
      }
    }
    tests = {
      readiness_url = "${local.operator_contract_service_url}/healthz/ready"
      admin_url     = "${local.operator_contract_service_url}/api/v1/admin"
      protocol_url  = "${local.operator_contract_service_url}/v1"
      mcp_url       = local.operator_contract_mcp_enabled ? "${local.operator_contract_service_url}${local.operator_contract_mcp_path}" : null
    }
    mcp = {
      enabled        = local.operator_contract_mcp_enabled
      profile        = local.operator_contract_mcp_enabled ? var.operator_contract_validation.mcp_profile : null
      transport      = local.operator_contract_mcp_enabled ? var.operator_contract_validation.mcp_transport : null
      required_tools = local.operator_contract_mcp_enabled ? var.operator_contract_validation.mcp_required_tools : []
    }
    test_data = {
      seed_mode            = try(var.operator_contract_validation.seed_mode, "smoke")
      tenant_prefix        = try(var.operator_contract_validation.tenant_prefix, "honua-it")
      reuse_data_stack     = var.existing_db_endpoint != ""
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
      reuse_data_stack = var.existing_db_endpoint != ""
      destroy_mode     = var.environment == "prod" ? "protected" : "ephemeral"
      ttl_hours        = local.operator_contract_ttl_hours
    }
    selectors = {
      account_id  = local.operator_contract_account_id
      region      = var.region
      cluster_arn = local.operator_contract_cluster_arn
      service_arn = local.operator_contract_service_arn
      log_group   = local.operator_contract_log_group
      tag_filters = var.tags
    }
  }

  operator_contract_operations_base = {
    schema_version = local.operator_contract_schema_version
    kind           = "operations"
    identity       = local.operator_contract_identity_base
    observability = {
      telemetry_policy      = module.honua.control_plane_telemetry_policy
      prometheus_job        = module.honua.control_plane_telemetry_prometheus_job
      prometheus_canary_job = module.honua.control_plane_telemetry_prometheus_canary_job
      log_group             = local.operator_contract_log_group
      metrics_namespace     = "Honua/${local.operator_contract_base_name}"
    }
    secrets = {
      provider   = "aws-secretsmanager"
      references = local.operator_contract_secret_registry
    }
    scaling = {
      deployment_mode  = var.deployment_mode
      desired_count    = var.desired_count
      max_capacity     = var.max_capacity
      cpu_architecture = var.task_cpu_architecture
    }
    resilience = {
      ingress_deletion_protection = var.alb_deletion_protection
      ingress_access_logs_enabled = var.alb_access_logs_enabled
      database_managed            = var.existing_db_endpoint == ""
      cache_enabled               = var.redis_enabled
    }
    grouping = {
      resource_group = local.operator_contract_cluster_name
      name_prefix    = var.name_prefix
      tags           = var.tags
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

  # Canonical digest input. jsonencode() sorts object keys and emits compact
  # JSON, which is byte-identical to the canonical form documented in
  # docs/operator-contract.md for the value space this contract allows.
  # contract_digest is absent here by construction, so the digest is not
  # self-referential.
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
  description = "Canonical honua.operator-contract/v1 deployment contract for AWS ECS. Authoritative handoff for honua-devops install."
  value       = local.deployment_contract

  # The deployed image and the contract's immutable claim have to be the same
  # artifact. Terraform will not resolve a tag to a digest, so a caller that
  # supplies an identity must also deploy the digest-pinned reference.
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
  description = "Canonical honua.operator-contract/v1 validation contract for AWS ECS. Authoritative handoff for verification, smoke, and teardown lanes."
  value       = local.validation_contract
}

output "operations_contract" {
  description = "Canonical honua.operator-contract/v1 operations contract for AWS ECS. Authoritative handoff for day-2 operations and runtime configuration."
  value       = local.operations_contract
}

output "operator_contract" {
  description = "Convenience envelope carrying all three honua.operator-contract/v1 contracts. Non-normative: the three contracts are the authoritative outputs."
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
