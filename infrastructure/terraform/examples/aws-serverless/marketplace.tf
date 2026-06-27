# Marketplace install/deploy contract surface.
#
# Implements the cross-repo marketplace contract advertised by
# marketplace/bundles/aws-serverless.v1.json:
#   - install            input variable  (marketplace/schemas/install-surface.v1.json)
#   - install_contract   normalized output of the effective install surface
#   - deploy_contract    output          (marketplace/schemas/deploy-contract.v2.json)
#
# The `install` variable is optional. When an attribute is supplied it overrides
# the matching flat input variable; when omitted the existing flat variable is
# used, so pre-existing tfvars keep working unchanged.

variable "install" {
  description = "Marketplace install surface (install-surface.v1.json). Optional; supplied attributes override the matching flat input variables."
  type = object({
    artifact = optional(object({
      image = optional(string)
      registry = optional(object({
        server      = optional(string)
        auth_mode   = optional(string)
        resource_id = optional(string)
      }))
    }))
    database = optional(object({
      host                    = optional(string)
      compute_sku             = optional(string)
      storage_gb              = optional(number)
      storage_mb              = optional(number)
      max_storage_gb          = optional(number)
      public_access           = optional(bool)
      postgis_enabled         = optional(bool)
      readiness_max_attempts  = optional(number)
      readiness_sleep_seconds = optional(number)
    }))
    network = optional(object({
      id                   = optional(string)
      cidr                 = optional(string)
      public_subnet_ids    = optional(list(string))
      private_subnet_ids   = optional(list(string))
      public_ingress_cidrs = optional(list(string))
      http_ingress_cidrs   = optional(list(string))
      https_ingress_cidrs  = optional(list(string))
      firewall_start_ip    = optional(string)
      firewall_end_ip      = optional(string)
    }))
    storage = optional(object({
      enabled        = optional(bool)
      name           = optional(string)
      container_name = optional(string)
      prefix         = optional(string)
      force_destroy  = optional(bool)
    }))
  })
  default = {}
}

locals {
  # Effective inputs: install-surface override, otherwise the flat variable.
  install_image = coalesce(try(var.install.artifact.image, null), var.honua_image_uri)

  install_db_host      = try(var.install.database.host, null) != null ? var.install.database.host : var.existing_db_endpoint
  install_db_public    = try(var.install.database.public_access, null) != null ? var.install.database.public_access : var.db_publicly_accessible
  install_db_postgis   = try(var.install.database.postgis_enabled, null) != null ? var.install.database.postgis_enabled : var.enable_postgis
  install_db_rdy_max   = try(var.install.database.readiness_max_attempts, null) != null ? var.install.database.readiness_max_attempts : var.postgis_readiness_max_attempts
  install_db_rdy_sleep = try(var.install.database.readiness_sleep_seconds, null) != null ? var.install.database.readiness_sleep_seconds : var.postgis_readiness_sleep_seconds

  install_net_id      = try(var.install.network.id, null) != null ? var.install.network.id : var.existing_vpc_id
  install_net_cidr    = try(var.install.network.cidr, null) != null ? var.install.network.cidr : var.existing_vpc_cidr
  install_net_pub_sub = try(var.install.network.public_subnet_ids, null) != null ? var.install.network.public_subnet_ids : var.existing_public_subnet_ids
  install_net_prv_sub = try(var.install.network.private_subnet_ids, null) != null ? var.install.network.private_subnet_ids : var.existing_private_subnet_ids

  install_storage_enabled = try(var.install.storage.enabled, null) != null ? var.install.storage.enabled : false

  # Normalized install surface (install-surface.v1.json). Null attributes are
  # omitted so the JSON stays schema-valid (no nulls for typed fields).
  install_contract = {
    artifact = merge(
      { image = local.install_image },
      try(var.install.artifact.registry, null) != null ? {
        registry = { for k, v in {
          server      = try(var.install.artifact.registry.server, null)
          auth_mode   = try(var.install.artifact.registry.auth_mode, null)
          resource_id = try(var.install.artifact.registry.resource_id, null)
        } : k => v if v != null }
      } : {}
    )
    database = merge(
      { for k, v in {
        host = local.install_db_host
      } : k => v if v != null },
      { for k, v in {
        readiness_max_attempts  = local.install_db_rdy_max
        readiness_sleep_seconds = local.install_db_rdy_sleep
      } : k => v if v != null },
      { for k, v in {
        public_access   = local.install_db_public
        postgis_enabled = local.install_db_postgis
      } : k => v if v != null },
    )
    network = merge(
      { for k, v in {
        id   = local.install_net_id
        cidr = local.install_net_cidr
      } : k => v if v != null },
      { for k, v in {
        public_subnet_ids  = local.install_net_pub_sub
        private_subnet_ids = local.install_net_prv_sub
      } : k => v if v != null },
    )
    storage = {
      enabled = local.install_storage_enabled
    }
  }

  # Normalized deploy contract (deploy-contract.v2.json).
  deploy_contract = {
    schema_version = "v2"
    backend_name   = module.honua.control_plane_backend_name
    target_kind    = module.honua.control_plane_target_kind
    target_id      = module.honua.control_plane_target_id
    target_name    = module.honua.control_plane_target_name
    resource_id    = module.honua.control_plane_target_resource_id
    resource_group = null
    endpoint       = module.honua.api_endpoint
    artifact_reference = {
      kind    = "container_image"
      current = local.install_image
      desired = local.install_image
    }
    current_revision = module.honua.control_plane_current_revision
    desired_revision = module.honua.control_plane_desired_revision
    secret_refs = { for k, v in {
      db_connection    = module.honua.db_connection_secret_arn
      redis_connection = nonsensitive(module.honua.redis_connection_secret_arn)
      pro_license      = module.honua.pro_license_secret_arn
    } : k => v if v != null }
    object_storage_refs = {
      enabled = local.install_storage_enabled
    }
    health_policy = {
      telemetry_policy = module.honua.control_plane_telemetry_policy
    }
  }
}

output "install_contract" {
  description = "Normalized marketplace install surface (install-surface.v1.json)."
  value       = local.install_contract
}

output "deploy_contract" {
  description = "Normalized marketplace deploy contract (deploy-contract.v2.json)."
  value       = local.deploy_contract
}
