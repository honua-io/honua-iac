###############################################################################
# Honua real-Azure certification tier — examples/azure-cert
#
# The Azure parallel of examples/aws-cert (honua-iac#2164). A Honua-owned stack
# that certifies the GP-over-Azure-Batch path against REAL Azure (no emulator):
#   - reuses modules/azure-gp with enable_azure_gp_substrate = true (the durable
#     SINGLE-POOL GP substrate: a Batch account + one autoscaling scale-to-zero
#     pool + worker-gdal ACR + task identity + blob output staging);
#   - a GitHub-OIDC-FEDERATED user-assigned identity (inline
#     azurerm_federated_identity_credential, the azurerm equivalent of the AWS
#     GitHub-OIDC provider, copied from components/cloud-demo-smoke-credentials)
#     so the dispatched cert workflow assumes it via azure/login@v2 with NO
#     client secret;
#   - role assignments the cert identity needs (Batch Contributor on the Batch
#     account, AcrPush on the worker-gdal ACR, Storage Blob Data Contributor on
#     the output account) — least-privilege, scoped to this stack's surface.
#
# name_prefix="honua-cert" + environment="cert" => honua-cert-cert-* surface.
#
# Serverless-everywhere / no-standing-compute: the Batch pool autoscales to zero
# (nothing warm between jobs) and the cert identity mints its credential per run
# via OIDC token exchange.
###############################################################################

data "azurerm_client_config" "current" {}

locals {
  name = "${var.name_prefix}-${var.environment}"

  tags = merge({
    Project     = "honua-server"
    Environment = "cert"
    ManagedBy   = "terraform"
    Purpose     = "real-azure-certification"
  }, var.tags)
}

# ---------------------------------------------------------------------------
# Azure GP substrate — SINGLE-POOL scale-to-zero (durable cert substrate).
# The honua-devops gp runtime adapter consumes the exported endpoints/ids as
# opaque config — it does NOT re-apply terraform per job. Only substrate-level
# inputs (VM size, ACR, node priority) are forwarded.
# ---------------------------------------------------------------------------

module "azure_gp" {
  source = "../../modules/azure-gp"

  name_prefix = var.name_prefix
  environment = var.environment
  location    = var.location

  enable_azure_gp_substrate = true

  gp_pool_vm_size          = var.gp_pool_vm_size
  gp_pool_use_low_priority = var.gp_pool_use_low_priority
  gp_pool_max_nodes        = var.gp_pool_max_nodes

  create_worker_gdal_acr = var.create_worker_gdal_acr
  worker_gdal_acr_sku    = var.worker_gdal_acr_sku

  tags = local.tags
}

# ---------------------------------------------------------------------------
# GitHub Actions -> Azure OIDC federation for the dispatched cert workflow.
# Copied from components/cloud-demo-smoke-credentials: a user-assigned identity
# + a federated credential (issuer token.actions.githubusercontent.com, audience
# api://AzureADTokenExchange) scoped by `sub` to the cert repo/environment. The
# workflow assumes it via azure/login@v2 — no client secret committed anywhere.
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "cert" {
  name                = "${local.name}-cert-identity"
  location            = var.location
  resource_group_name = module.azure_gp.gp_resource_group_name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "cert" {
  name                = "${local.name}-cert-gha"
  resource_group_name = module.azure_gp.gp_resource_group_name
  parent_id           = azurerm_user_assigned_identity.cert.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = var.github_oidc_subject
}

# ---------------------------------------------------------------------------
# Role assignments the cert identity needs to drive the GP substrate.
# Least-privilege, scoped to this stack's resources (NOT subscription-wide).
# ---------------------------------------------------------------------------

# Submit / observe / terminate Batch jobs on the cert Batch account.
resource "azurerm_role_assignment" "cert_batch_contributor" {
  scope                = module.azure_gp.gp_batch_account_id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.cert.principal_id
}

# Push the worker-gdal image to the cert ACR.
resource "azurerm_role_assignment" "cert_acr_push" {
  count                = var.create_worker_gdal_acr ? 1 : 0
  scope                = module.azure_gp.gp_acr_id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.cert.principal_id
}

# Read/write the GP output container for certification evidence.
resource "azurerm_role_assignment" "cert_blob" {
  scope                = module.azure_gp.gp_output_storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.cert.principal_id
}
