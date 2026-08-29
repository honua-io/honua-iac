# Canonical honua.operator-contract/v1 producer for the AWS certification root.
#
# Schema: infrastructure/terraform/contracts/operator-contract.v1.schema.json
# Spec:   docs/operator-contract.md
# Peer:   examples/aws/operator-contract.tf (the ECS/Fargate producer)
#
# Rules this file exists to hold (identical to the ECS producer):
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
#
# What differs from examples/aws, and why. This root composes
# modules/aws-serverless (Lambda behind an HTTP API Gateway) plus the GP and
# custom-code AWS Batch substrates, not modules/aws-ecs. The contract is a
# projection of THIS stack, not a copy of the ECS one:
#
#   - stack.runtime is "lambda"; the workload is a Lambda alias, not an ECS
#     service, so workload.cluster_id and validation selectors that name a
#     cluster/service are null rather than invented.
#   - rollout.current_revision / desired_revision ARE projected here. The ECS
#     producer nulls them because a task-set revision is observed by the
#     rollout controller after apply; a Lambda alias's function version is
#     Terraform-owned state, so projecting it claims nothing Terraform cannot
#     prove.
#   - rollout.canary is disabled. The stack's ECS/ALB weighted-cutover cell
#     (ecs-alb-cert.tf) is a certification FIXTURE for the server's
#     AwsEcsAlbDeployBackend, not a canary of this Lambda workload. Presenting
#     it as rollout.canary would be a false claim, so it is surfaced under
#     deployment_contract.extensions instead.
#   - dependencies.object_storage is disabled. modules/aws-serverless exposes
#     no Honua file-storage provider, and the cert artifact bucket is GP/
#     custom-code job scratch plus evidence storage - not the application's
#     object-storage backend. It too is surfaced under extensions.
#
# Two schema fields have no honest serverless analogue and are documented at
# their point of use: workload.cluster_name and workload.desired_count, plus
# operations.scaling.desired_count / max_capacity. See the comments inline.

data "aws_caller_identity" "operator_contract" {}

data "aws_partition" "operator_contract" {}

variable "operator_contract_identity" {
  description = "Optional immutable identity inputs for the honua.operator-contract/v1 output. Omit only for disposable, unqualified development plans; certified consumers must provide every required digest and backend/state lineage input."
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
      (try(var.operator_contract_identity.state_serial, null) == null || try(var.operator_contract_identity.state_serial >= 0, false))
    )
    error_message = "operator_contract_identity must use SHA-256 digests, a 40/64-character IaC revision, a sha256 image digest, a UUID state lineage, and a non-negative state serial when supplied."
  }

  # An immutable identity claim may never be backed by a mutable reference.
  # image_reference must be registry/repository@sha256:<64 hex>; a tag-only
  # reference (":latest", ":2026.1.0") is rejected here rather than silently
  # projected into the contract as an immutable pin.
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
  description = "Optional validation-lane inputs projected into the honua.operator-contract/v1 validation contract. Defaults describe the certification cell with MCP disabled."
  type = object({
    mcp_enabled        = optional(bool, false)
    mcp_profile        = optional(string)
    mcp_transport      = optional(string)
    mcp_path           = optional(string)
    mcp_required_tools = optional(list(string), [])
    seed_mode          = optional(string, "smoke")
    tenant_prefix      = optional(string, "honua-cert")
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

  operator_contract_root   = "infrastructure/terraform/examples/aws-cert"
  operator_contract_module = "infrastructure/terraform/modules/aws-serverless"

  operator_contract_partition  = data.aws_partition.operator_contract.partition
  operator_contract_account_id = data.aws_caller_identity.operator_contract.account_id

  # Every name below is read from a module output or derived from one, so the
  # projection cannot drift from what this root actually provisions.
  operator_contract_function_name = module.honua.lambda_function_name
  operator_contract_service_url   = module.honua.api_endpoint

  # modules/aws-serverless names the Lambda log group "/aws/lambda/<function>".
  # Deriving it from the function-name output is a naming derivation, not an
  # identity claim.
  operator_contract_log_group = "/aws/lambda/${local.operator_contract_function_name}"

  # The API Gateway default endpoint is https://<api-id>.execute-api.<region>.
  # amazonaws.com; the host is the ingress DNS name.
  operator_contract_ingress_dns_name = replace(local.operator_contract_service_url, "https://", "")

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

  operator_contract_mcp_enabled = try(var.operator_contract_validation.mcp_enabled, false)
  operator_contract_mcp_path    = local.operator_contract_mcp_enabled ? var.operator_contract_validation.mcp_path : null
  operator_contract_ttl_hours   = try(var.operator_contract_validation.ttl_hours, null)

  # Derived from state rather than from the literal `redis_enabled = false` in
  # main.tf, so flipping the module input cannot silently falsify the contract.
  operator_contract_redis_secret_arn = nonsensitive(module.honua.redis_connection_secret_arn)
  operator_contract_cache_enabled    = local.operator_contract_redis_secret_arn != null

  operator_contract_pro_license_secret_arn = module.honua.pro_license_secret_arn

  # This root never passes existing_db_endpoint / existing_db_connection_string
  # to modules/aws-serverless (see main.tf), so the certification database is
  # always module-managed.
  operator_contract_database_managed = true

  # Secret references only. Nulls are dropped so a consumer never has to decide
  # what an absent-but-present key means.
  #
  # There is deliberately no connection_encryption_master_key entry: this root
  # reuses honua_admin_password as Security__ConnectionEncryption__MasterKey
  # (see variables.tf), so no separate secret exists to reference. Inventing a
  # key here would name a secret that is not provisioned.
  operator_contract_deployment_secret_refs = { for name, arn in {
    admin_password   = module.honua.admin_password_secret_arn
    db_connection    = module.honua.db_connection_secret_arn
    redis_connection = local.operator_contract_redis_secret_arn
    pro_license      = local.operator_contract_pro_license_secret_arn
  } : name => arn if arn != null }

  operator_contract_secret_registry = { for name, ref in {
    admin_password = {
      kind        = "admin_password"
      provider    = "aws-secretsmanager"
      id          = module.honua.admin_password_secret_arn
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
    redis_connection = local.operator_contract_redis_secret_arn == null ? null : {
      kind        = "redis_connection"
      provider    = "aws-secretsmanager"
      id          = local.operator_contract_redis_secret_arn
      kms_key_ref = null
      managed_by  = "honua-iac"
    }
    # The Pro license envelope has no dedicated `kind` in the v1 enum, so it is
    # typed "other" rather than mislabelled as one of the named kinds.
    pro_license = local.operator_contract_pro_license_secret_arn == null ? null : {
      kind        = "other"
      provider    = "aws-secretsmanager"
      id          = local.operator_contract_pro_license_secret_arn
      kms_key_ref = null
      managed_by  = module.honua.pro_license_secret_managed_by_terraform ? "honua-iac" : "operator"
    }
  } : name => ref if ref != null }

  # Additive certification facts. Extensions may add facts; they must never
  # restate, override, or reinterpret a core field - so nothing here duplicates
  # a value the core contract already carries under a different name.
  operator_contract_cert_extensions = {
    artifact_bucket = aws_s3_bucket.cert_artifacts.bucket
    geoprocessing_batch = {
      enabled               = module.honua.gp_batch_enabled
      job_queue_arn         = module.honua.gp_job_queue_arn
      job_definition_arns   = module.honua.gp_job_definition_arns
      compute_environment   = module.honua.gp_compute_environment_arn
      job_role_arn          = module.honua.gp_job_role_arn
      execution_role_arn    = module.honua.gp_execution_role_arn
      control_plane_backend = module.honua.gp_batch_control_plane_backend_name
      workload_id           = module.honua.gp_batch_workload_id
    }
    customcode_batch = {
      enabled             = module.honua.customcode_batch_enabled
      job_queue_arn       = module.honua.customcode_job_queue_arn
      job_definition_arns = module.honua.customcode_job_definition_arns
      task_role_arn       = module.honua.customcode_task_role_arn
      runtimes            = module.honua.customcode_runtimes
    }
    # The server's production AwsEcsAlbDeployBackend certifies weighted cutover
    # against these real ELBv2/ECS resources. It is a fixture the certification
    # lane drives directly, NOT the rollout path of this stack's workload.
    ecs_alb_cutover_cell = {
      enabled                 = local.ecs_alb_enabled
      cluster_name            = one(aws_ecs_cluster.cert_cutover[*].name)
      cluster_arn             = one(aws_ecs_cluster.cert_cutover[*].arn)
      service_name            = one(aws_ecs_service.cert_cutover[*].name)
      listener_arn            = one(aws_lb_listener.cert_cutover[*].arn)
      stable_target_group_arn = one(aws_lb_target_group.cert_cutover_stable[*].arn)
      canary_target_group_arn = one(aws_lb_target_group.cert_cutover_canary[*].arn)
    }
    github_oidc_role_arn = module.github_oidc.role_arn
  }

  operator_contract_deployment_base = {
    schema_version = local.operator_contract_schema_version
    kind           = "deployment"
    identity       = local.operator_contract_identity_base
    extensions     = local.operator_contract_cert_extensions
    stack = {
      id          = "aws-cert-serverless"
      platform    = "aws"
      runtime     = "lambda"
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
      ingress_dns_name = local.operator_contract_ingress_dns_name
      # No custom domain is provisioned for the certification endpoint.
      custom_domain = null
    }
    workload = {
      kind        = module.honua.control_plane_target_kind
      name        = local.operator_contract_function_name
      resource_id = module.honua.lambda_alias_arn
      # v1 requires a non-empty cluster_name and this runtime has no cluster.
      # The stack's resource-group name is projected as the grouping key (the
      # same value as operations.grouping.resource_group); cluster_id stays
      # null because there is no cluster ARN to name. A consumer must not read
      # this as an ECS cluster.
      cluster_name = local.name
      cluster_id   = null
      # main.tf pins the Lambda to a single architecture; see local.lambda_architecture.
      cpu_architecture = local.lambda_architecture
      # v1 requires an integer desired_count and Lambda has no desired count:
      # concurrency is demand-driven and this root reserves none. 0 records
      # "no standing instance count is declared by this root", which is the
      # honest reading for a scale-to-zero runtime.
      desired_count = 0
      identity      = try(local.operator_contract_identity_input.workload_identity, null)
    }
    rollout = {
      backend_name    = module.honua.control_plane_backend_name
      target_kind     = module.honua.control_plane_target_kind
      target_id       = module.honua.control_plane_target_id
      target_name     = module.honua.control_plane_target_name
      target_resource = module.honua.control_plane_target_resource_id
      # Unlike the ECS root, these are Terraform-owned state for a Lambda
      # alias, so projecting them claims nothing Terraform cannot prove.
      current_revision = module.honua.control_plane_current_revision
      desired_revision = module.honua.control_plane_desired_revision
      # This workload has no canary. The ECS/ALB weighted-cutover cell is a
      # certification fixture, not a canary of the Lambda; it is reported under
      # extensions.ecs_alb_cutover_cell.
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
        managed    = local.operator_contract_database_managed
        endpoint   = nonsensitive(module.honua.db_endpoint)
        secret_ref = module.honua.db_connection_secret_arn
      }
      cache = {
        kind       = "aws-elasticache-redis"
        enabled    = local.operator_contract_cache_enabled
        secret_ref = local.operator_contract_redis_secret_arn
      }
      ingress = {
        kind     = "aws-apigatewayv2-http"
        endpoint = local.operator_contract_service_url
        # The API Gateway default endpoint terminates TLS with an AWS-managed
        # certificate that exposes no ACM ARN, and no WAF is attached.
        certificate_ref = null
        waf_ref         = null
      }
      # modules/aws-serverless exposes no Honua file-storage provider. The cert
      # artifact bucket is GP/custom-code job scratch plus evidence storage, not
      # the application's object-storage backend, so it is reported under
      # extensions.artifact_bucket rather than claimed here.
      object_storage = {
        kind    = null
        enabled = false
        bucket  = null
        prefix  = null
      }
    }
    secret_refs = local.operator_contract_deployment_secret_refs
  }

  operator_contract_validation_base = {
    schema_version = local.operator_contract_schema_version
    kind           = "validation"
    identity       = local.operator_contract_identity_base
    extensions     = local.operator_contract_cert_extensions
    platform = {
      name = "aws-cert-serverless"
      capabilities = {
        deploy_plan = true
        # Real control-plane mutation is certified against the ECS/ALB cutover
        # cell; with the cell off there is no mutation surface in this stack.
        mutation = local.ecs_alb_enabled
        # No horizontal scale control exists for an unreserved Lambda alias.
        scale_check   = false
        backup_drill  = local.operator_contract_database_managed
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
      seed_mode     = try(var.operator_contract_validation.seed_mode, "smoke")
      tenant_prefix = try(var.operator_contract_validation.tenant_prefix, "honua-cert")
      # The certification root always mints its own data stack.
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
      account_id = local.operator_contract_account_id
      region     = var.region
      # A Lambda workload has neither a cluster nor a service. The cutover
      # cell's ARNs are certification-fixture selectors, not workload
      # selectors, and are reported under extensions.
      cluster_arn = null
      service_arn = null
      log_group   = local.operator_contract_log_group
      tag_filters = local.tags
    }
  }

  operator_contract_operations_base = {
    schema_version = local.operator_contract_schema_version
    kind           = "operations"
    identity       = local.operator_contract_identity_base
    extensions     = local.operator_contract_cert_extensions
    observability = {
      telemetry_policy = module.honua.control_plane_telemetry_policy
      # modules/aws-serverless ships no Prometheus scrape target; CloudWatch is
      # the only telemetry sink here.
      prometheus_job        = null
      prometheus_canary_job = null
      log_group             = local.operator_contract_log_group
      metrics_namespace     = "Honua/${local.name}"
    }
    secrets = {
      provider   = "aws-secretsmanager"
      references = local.operator_contract_secret_registry
    }
    scaling = {
      deployment_mode = "Serverless"
      # As in workload.desired_count: a demand-driven Lambda alias declares no
      # standing instance count, and this root reserves no concurrency, so v1's
      # required integers record "none declared" rather than a made-up ceiling.
      desired_count    = 0
      max_capacity     = 0
      cpu_architecture = local.lambda_architecture
    }
    resilience = {
      # An HTTP API Gateway stage exposes no deletion-protection control.
      ingress_deletion_protection = false
      # modules/aws-serverless always configures stage access logging.
      ingress_access_logs_enabled = true
      database_managed            = local.operator_contract_database_managed
      cache_enabled               = local.operator_contract_cache_enabled
    }
    grouping = {
      resource_group = local.name
      name_prefix    = var.name_prefix
      tags           = local.tags
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
  description = "Canonical honua.operator-contract/v1 deployment contract for the AWS certification root. Authoritative handoff for honua-devops install."
  value       = local.deployment_contract

  # The deployed image and the contract's immutable claim have to be the same
  # artifact. Terraform will not resolve a tag to a digest, so a caller that
  # supplies an identity must also deploy the digest-pinned reference.
  precondition {
    condition     = local.operator_contract_image_reference == null || var.honua_image == local.operator_contract_image_reference
    error_message = "The deployed image (${var.honua_image}) does not match operator_contract_identity.image_reference. Deploy the digest-pinned reference; Terraform will not convert a mutable tag into an immutable claim."
  }

  precondition {
    condition     = local.operator_contract_identity_input == null || can(regex("@sha256:[0-9a-f]{64}$", var.honua_image))
    error_message = "The deployed image (${var.honua_image}) is not digest-pinned. An operator contract carrying immutable identity requires an image reference of the form registry/repository@sha256:<64 hex>."
  }
}

output "validation_contract" {
  description = "Canonical honua.operator-contract/v1 validation contract for the AWS certification root. Authoritative handoff for verification, smoke, and teardown lanes."
  value       = local.validation_contract
}

output "operations_contract" {
  description = "Canonical honua.operator-contract/v1 operations contract for the AWS certification root. Authoritative handoff for day-2 operations and runtime configuration."
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
