###############################################################################
# Azure Batch (single-pool) compute for Honua geoprocessing / import jobs.
#
# "GP over Batch" on Azure: the Honua server's ExecutionJobReconciler submits and
# observes geoprocessing/import jobs via the AzureBatchComputeBackend
# (Backend=honua-azure-batch). Unlike AWS Batch (which sizes per-task and mints a
# POOL of job definitions differing by ephemeral storage), Azure Batch sizes
# per-POOL (VM size). So the Azure substrate is intentionally a SINGLE POOL:
#   - one Batch account (its account_endpoint is the data-plane URL the server
#     reads as azure.batch.account_url);
#   - ONE container-capable pool that autoscales from 0 -> N on pending tasks and
#     back to 0 when idle (the Azure scale-to-zero analog of Fargate-Spot);
#   - a user-assigned identity the pool/tasks run under (the IAM job-role analog);
#   - an ACR hosting the worker-gdal image (the ECR analog);
#   - a storage account + blob container for task output staging.
# Per-job knobs (image, command line, retry, timeout, env) are SubmitTask-time
# runtime parameters the server applies, NOT terraform — so terraform owns only
# the durable substrate. The 4-tier pool (per-tier VM sizes) is a fast-follow;
# the MVP runs one pool because Azure scale-to-zero economics favor it.
#
# Cost posture (budget-tight demo):
#   - Low-priority (Spot) nodes by default (gp_pool_use_low_priority) — far
#     cheaper, with documented preemption risk for long jobs.
#   - Autoscale to zero between jobs: no node stays warm, you pay only while a
#     job's container actually runs.
#
# Toggled off by default (enable_azure_gp_substrate = false) so existing deploys
# are unchanged unless an operator opts in. Mirrors enable_gp_batch on AWS.
###############################################################################

data "azurerm_client_config" "current" {}

locals {
  gp_enabled = var.enable_azure_gp_substrate
  count_flag = local.gp_enabled ? 1 : 0

  name = "${var.name_prefix}-${var.environment}"

  tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "gp-azure-batch"
    Issue       = "honua-iac#70-azure"
  }, var.tags)

  # Azure Batch account names: 3-24 chars, lowercase alphanumeric only.
  batch_account_name = substr(replace(lower("${local.name}gpbatch"), "/[^a-z0-9]/", ""), 0, 24)
  # Storage account names: 3-24 chars, lowercase alphanumeric only.
  storage_account_name = substr(replace(lower("${local.name}gpout${random_string.storage_suffix.result}"), "/[^a-z0-9]/", ""), 0, 24)
  # ACR names: 5-50 chars, lowercase alphanumeric only. Stable regardless of the
  # create flag so an operator can pre-create + push, then flip the flag on.
  acr_name = substr(replace(lower("${local.name}workergdal"), "/[^a-z0-9]/", ""), 0, 50)

  # The single GP pool id (the server reads this as azure.batch.pool_id).
  gp_pool_id = "${local.name}-gp"

  # ---------------------------------------------------------------------------
  # Autoscale formula — scale-to-zero on idle, scale-up on pending tasks.
  #
  # Azure Batch evaluates this on gp_pool_autoscale_evaluation_interval. It is the
  # Azure analog of the AWS Fargate compute-environment scaling to min_vcpus=0.
  # Logic:
  #   - $PendingTasks samples queued (active) tasks over the last interval; we take
  #     the MAX over a short look-back so a brief sampling gap doesn't scale down a
  #     pool that still has work. Running tasks are protected on scale-down by the
  #     taskcompletion deallocation option (below), so draining queued count to 0
  #     never kills an in-flight job.
  #   - $targetNodes = that pending count, CAPPED at gp_pool_max_nodes.
  #   - When there is NO work the target is 0 -> the pool drains to zero nodes
  #     (scale-to-zero); you pay only while a job runs.
  #   - taskcompletion deallocation lets an in-flight task finish before its node
  #     is reclaimed on scale-down (no mid-task node kill from autoscale).
  # The target is assigned to either the low-priority or the dedicated node knob
  # depending on gp_pool_use_low_priority; the other knob is pinned to 0.
  # ---------------------------------------------------------------------------
  autoscale_target_var = var.gp_pool_use_low_priority ? "$TargetLowPriorityNodes" : "$TargetDedicatedNodes"
  autoscale_zero_var   = var.gp_pool_use_low_priority ? "$TargetDedicatedNodes" : "$TargetLowPriorityNodes"

  gp_autoscale_formula = <<-EOT
    // Honua GP scale-to-zero autoscale formula (single-pool MVP).
    // Look back over the sampling interval; use the max so a sampling gap does
    // not prematurely scale a still-busy pool to zero.
    $samples = $PendingTasks.GetSamplePercent(TimeInterval_Minute * 5);
    $pending = ($samples < 50 ? max(0, $PendingTasks.GetSample(1)) : max($PendingTasks.GetSample(TimeInterval_Minute * 5)));
    // Target one node per pending task, capped by the configured ceiling.
    // No pending work => target 0 => pool drains to zero (scale-to-zero).
    $target = min($pending, ${var.gp_pool_max_nodes});
    ${local.autoscale_target_var} = $target;
    ${local.autoscale_zero_var} = 0;
    // Let an in-flight task finish before its node is reclaimed on scale-down.
    $NodeDeallocationOption = taskcompletion;
  EOT

  # start_task that logs the node into ACR via the pool's user-assigned identity
  # (managed-identity auth, no registry password). Only emitted when the ACR is
  # created in-module; otherwise the operator wires their own registry.
  acr_login_server = var.create_worker_gdal_acr ? azurerm_container_registry.worker_gdal[0].login_server : ""
}

resource "random_string" "storage_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "this" {
  count    = local.count_flag
  name     = "${local.name}-gp-rg"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# Task identity (the IAM job-role equivalent). The pool runs under this
# user-assigned identity; tasks inherit it for ACR pull, blob writes, and the
# optional Key Vault read.
# ---------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "gp_task" {
  count               = local.count_flag
  name                = "${local.name}-gp-task"
  location            = azurerm_resource_group.this[0].location
  resource_group_name = azurerm_resource_group.this[0].name
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Worker-gdal Azure Container Registry (the ECR equivalent, optional).
# Off by default (create_worker_gdal_acr = false). Name is deterministic so an
# operator can pre-create + push, then flip the flag on. Admin user disabled —
# the pool authenticates via its managed identity (AcrPull below).
# ---------------------------------------------------------------------------

#checkov:skip=CKV_AZURE_139: Public network access stays enabled so scale-to-zero Batch nodes (no fixed egress IP / private endpoint in the MVP) can pull the worker image; pulls are gated by the pool identity's AcrPull grant (admin user disabled).
#checkov:skip=CKV_AZURE_163: Vulnerability scanning (Defender for Containers) is a subscription-level capability operators enable separately, not a registry resource attribute.
#checkov:skip=CKV_AZURE_164: Content-trust / signed-image enforcement is a Premium-only feature; the cost-default Standard worker-gdal registry pulls images built and signed by trusted CI.
#checkov:skip=CKV_AZURE_165: Geo-replication is a Premium-only feature; the worker-gdal registry defaults to Standard for cost and is single-region for cert/demo.
#checkov:skip=CKV_AZURE_166: Image quarantine is not required for the GP worker image; images are built and pushed by trusted CI, not arbitrary publishers.
#checkov:skip=CKV_AZURE_167: Retention policy (untagged-manifest cleanup) is a Premium-only feature; the Standard worker-gdal registry relies on operational image hygiene.
#checkov:skip=CKV_AZURE_233: Zone redundancy is a Premium-only feature; the cost-default Standard registry is single-zone for cert/demo.
resource "azurerm_container_registry" "worker_gdal" {
  count = local.gp_enabled && var.create_worker_gdal_acr ? 1 : 0
  #checkov:skip=CKV_AZURE_139: see resource note.
  #checkov:skip=CKV_AZURE_163: see resource note.
  #checkov:skip=CKV_AZURE_164: see resource note.
  #checkov:skip=CKV_AZURE_165: see resource note.
  #checkov:skip=CKV_AZURE_166: see resource note.
  #checkov:skip=CKV_AZURE_167: see resource note.
  #checkov:skip=CKV_AZURE_233: see resource note.
  name                          = local.acr_name
  resource_group_name           = azurerm_resource_group.this[0].name
  location                      = azurerm_resource_group.this[0].location
  sku                           = var.worker_gdal_acr_sku
  admin_enabled                 = false
  public_network_access_enabled = true

  tags = local.tags
}

# Pool/task identity may PULL the worker-gdal image (managed-identity registry
# auth, no password) — the AcrPull role assignment.
resource "azurerm_role_assignment" "gp_task_acr_pull" {
  count                = local.gp_enabled && var.create_worker_gdal_acr ? 1 : 0
  scope                = azurerm_container_registry.worker_gdal[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.gp_task[0].principal_id
}

# ---------------------------------------------------------------------------
# Storage account + blob container for GP task output staging. The server
# already uploads task output here; the container URL is surfaced as
# azure.storage.output_container_url.
# ---------------------------------------------------------------------------

#checkov:skip=CKV_AZURE_33: Queue logging is not required for the GP output blob store (no queues used); operators can layer it on.
#checkov:skip=CKV_AZURE_59: Public network access stays enabled so scale-to-zero Batch nodes (no fixed egress IP / private endpoint in the MVP) can reach the output container; access is gated by Azure AD RBAC (the task identity's Storage Blob Data Contributor grant), not anonymous access.
#checkov:skip=CKV_AZURE_190: Blob public access is disabled (allow_nested_items_to_be_public = false); network restriction is layered by operators.
#checkov:skip=CKV_AZURE_206: Replication strategy stays configurable so cost-sensitive cert/demo environments can use LRS.
#checkov:skip=CKV2_AZURE_1: SSE with a customer-managed key is not required for reproducible GP output; the account uses Microsoft-managed encryption at rest.
#checkov:skip=CKV2_AZURE_18: Customer-managed-key encryption omitted; GP output is reproducible cert/demo data.
#checkov:skip=CKV2_AZURE_33: Private endpoint not used in the MVP; the scale-to-zero pool reaches blob over the public endpoint gated by AAD RBAC.
#checkov:skip=CKV2_AZURE_40: Shared-key access is disabled below (shared_access_key_enabled = false); the task identity uses AAD tokens.
#checkov:skip=CKV2_AZURE_41: SAS-token policy not configured; blob access is via AAD RBAC, not SAS.
#checkov:skip=CKV2_AZURE_47: Blob anonymous access is disabled (allow_nested_items_to_be_public = false).
resource "azurerm_storage_account" "gp_output" {
  count = local.count_flag
  #checkov:skip=CKV_AZURE_33: see resource note.
  #checkov:skip=CKV_AZURE_59: see resource note.
  #checkov:skip=CKV_AZURE_190: see resource note.
  #checkov:skip=CKV_AZURE_206: see resource note.
  #checkov:skip=CKV2_AZURE_1: see resource note.
  #checkov:skip=CKV2_AZURE_18: see resource note.
  #checkov:skip=CKV2_AZURE_33: see resource note.
  #checkov:skip=CKV2_AZURE_40: see resource note.
  #checkov:skip=CKV2_AZURE_41: see resource note.
  #checkov:skip=CKV2_AZURE_47: see resource note.
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.this[0].name
  location                        = azurerm_resource_group.this[0].location
  account_tier                    = "Standard"
  account_replication_type        = var.storage_account_replication_type
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "gp_output" {
  count                 = local.count_flag
  name                  = var.gp_output_container_name
  storage_account_id    = azurerm_storage_account.gp_output[0].id
  container_access_type = "private"
}

# Pool/task identity may read+write the output container (blob upload from GP
# tasks). Storage Blob Data Contributor scoped to the account.
resource "azurerm_role_assignment" "gp_task_blob" {
  count                = local.count_flag
  scope                = azurerm_storage_account.gp_output[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.gp_task[0].principal_id
}

# Optional: grant the task identity read access to a caller-supplied Key Vault
# (e.g. the vault holding the DB connection string the GP container resolves).
resource "azurerm_role_assignment" "gp_task_kv_read" {
  count                = local.gp_enabled && trimspace(var.gp_task_key_vault_id) != "" ? 1 : 0
  scope                = var.gp_task_key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.gp_task[0].principal_id
}

# ---------------------------------------------------------------------------
# Batch account — the control surface. Its account_endpoint is the data-plane
# URL the server reads as azure.batch.account_url. Pool-allocation in the Batch
# service (default) so the account does not pin a subscription quota; the pool
# autoscales to zero.
# ---------------------------------------------------------------------------

resource "azurerm_batch_account" "gp" {
  count                = local.count_flag
  name                 = local.batch_account_name
  resource_group_name  = azurerm_resource_group.this[0].name
  location             = azurerm_resource_group.this[0].location
  pool_allocation_mode = "BatchService"
  tags                 = local.tags
}

# ---------------------------------------------------------------------------
# The single GP pool — container-capable, autoscaling scale-to-zero.
#
# target_dedicated_nodes / target_low_priority_nodes are NOT set because
# auto_scale owns the node targets (terraform fixing them conflicts with
# autoscale). The container_configuration + node_agent_sku_id make this a
# container host; the start_task logs the node into ACR via the pool identity.
# ---------------------------------------------------------------------------

resource "azurerm_batch_pool" "gp" {
  count               = local.count_flag
  name                = local.gp_pool_id
  resource_group_name = azurerm_resource_group.this[0].name
  account_name        = azurerm_batch_account.gp[0].name
  display_name        = "Honua Geoprocessing (Azure Batch)"
  vm_size             = var.gp_pool_vm_size
  node_agent_sku_id   = var.gp_node_agent_sku_id

  # Pool runs under the GP task identity (ACR pull, blob writes inherit from it).
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.gp_task[0].id]
  }

  # Scale-to-zero: the autoscale formula drives node count from pending tasks and
  # back to 0 when idle. No fixed target_*_nodes (would conflict with autoscale).
  auto_scale {
    evaluation_interval = var.gp_pool_autoscale_evaluation_interval
    formula             = local.gp_autoscale_formula
  }

  storage_image_reference {
    publisher = var.gp_pool_image_reference.publisher
    offer     = var.gp_pool_image_reference.offer
    sku       = var.gp_pool_image_reference.sku
    version   = var.gp_pool_image_reference.version
  }

  # Container-capable host. When the worker-gdal ACR is created in-module, it is
  # registered as a container registry the node can pull from via the pool's
  # user-assigned identity (no password).
  container_configuration {
    type = "DockerCompatible"

    dynamic "container_registries" {
      for_each = var.create_worker_gdal_acr ? [1] : []
      content {
        registry_server           = azurerm_container_registry.worker_gdal[0].login_server
        user_assigned_identity_id = azurerm_user_assigned_identity.gp_task[0].id
      }
    }
  }

  # start_task: log the node into ACR so cached image pulls use managed-identity
  # auth. Only meaningful when the ACR is created in-module. Runs as a privileged
  # pool-admin task so it can configure the container runtime's auth.
  dynamic "start_task" {
    for_each = var.create_worker_gdal_acr ? [1] : []
    content {
      command_line       = "/bin/bash -c \"az login --identity --username ${azurerm_user_assigned_identity.gp_task[0].client_id} && az acr login --name ${azurerm_container_registry.worker_gdal[0].name}\""
      task_retry_maximum = 1
      wait_for_success   = true
      common_environment_properties = {
        HONUA_GP_ACR = local.acr_login_server
      }

      user_identity {
        auto_user {
          elevation_level = "Admin"
          scope           = "Pool"
        }
      }
    }
  }
}
