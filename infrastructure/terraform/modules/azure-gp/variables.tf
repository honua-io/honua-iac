###############################################################################
# Inputs for the Azure GP-on-Batch substrate (modules/azure-gp).
#
# The Azure equivalent of modules/aws-serverless' GP substrate (honua-iac#70).
# Azure Batch sizes per-POOL (VM size), not per-task, so this is a SINGLE-POOL
# MVP: one Batch account + one autoscaling (scale-to-zero) pool + ACR + a task
# identity + blob output staging. Per-job knobs (command line, container image,
# retry, timeout, env) are SubmitTask-time runtime parameters applied by the
# server's AzureBatchComputeBackend — NOT terraform variables — so there are
# intentionally no per-job gp_* knobs here. The 4-tier pool is a fast-follow.
###############################################################################

variable "name_prefix" {
  description = "Prefix used for resource names. Combined with environment yields the resource surface (e.g. honua-cert-cert-*)."
  type        = string
  default     = "honua"
}

variable "environment" {
  description = "Environment name (e.g. cert, demo, prod). Combined with name_prefix for resource names and tagging."
  type        = string
}

variable "location" {
  description = "Azure region for the GP substrate resources."
  type        = string
  default     = "eastus"
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}

variable "enable_azure_gp_substrate" {
  description = "Master feature gate. When false (default) the module provisions nothing — mirrors enable_gp_batch on the AWS side so existing deploys are unchanged unless an operator opts in."
  type        = bool
  default     = false
}

# --- Batch pool sizing (single-pool MVP) -----------------------------------

variable "gp_pool_vm_size" {
  description = "VM size for the single GP Batch pool. Azure Batch sizes per-pool, so this is the substrate-level compute knob (the AWS Fargate per-task vCPU/memory equivalent is fixed at the pool here). Default Standard_D4s_v3 (4 vCPU / 16 GiB) suits typical GDAL geoprocessing."
  type        = string
  default     = "Standard_D4s_v3"
}

variable "gp_pool_use_low_priority" {
  description = "Use low-priority (Spot) nodes for the GP pool (cheaper, but Azure can preempt them). When true the autoscale formula drives the low-priority target; when false it drives dedicated nodes. PREEMPTION RISK: low-priority nodes can be reclaimed mid-job, so long-running GP jobs that cannot checkpoint should set this false (dedicated)."
  type        = bool
  default     = true
}

variable "gp_pool_max_nodes" {
  description = "Ceiling the autoscale formula will scale the GP pool up to. Bounds cost; pending tasks beyond this queue until a node frees."
  type        = number
  default     = 4

  validation {
    condition     = var.gp_pool_max_nodes >= 1
    error_message = "gp_pool_max_nodes must be at least 1."
  }
}

variable "gp_pool_autoscale_evaluation_interval" {
  description = "How often Azure Batch re-evaluates the autoscale formula (ISO-8601 duration; min PT5M)."
  type        = string
  default     = "PT5M"
}

variable "gp_node_agent_sku_id" {
  description = "Batch node agent SKU id for the container-capable VM image. Must match the image_reference; the default targets Ubuntu 22.04 with the Docker-compatible node agent."
  type        = string
  default     = "batch.node.ubuntu 22.04"
}

variable "gp_pool_image_reference" {
  description = "Marketplace image for the container-capable pool nodes (must carry a container runtime / be paired with a matching node_agent_sku_id). Defaults to the Azure Batch Ubuntu 22.04 container image."
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "microsoft-azure-batch"
    offer     = "ubuntu-server-container"
    sku       = "20-04-lts"
    version   = "latest"
  }
}

# --- Worker-gdal Azure Container Registry (the ECR equivalent) --------------

variable "create_worker_gdal_acr" {
  description = "Create the dedicated worker-gdal Azure Container Registry that hosts the GP/GDAL worker image (the ECR-repo equivalent). Mirrors create_worker_gdal_repo. The ACR name is derived deterministically so an operator can pre-create + push, then flip this on."
  type        = bool
  default     = false
}

variable "worker_gdal_acr_sku" {
  description = "SKU for the worker-gdal ACR (Basic/Standard/Premium). Premium is required for private endpoints / geo-replication; Standard is the cost-sensible default."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.worker_gdal_acr_sku)
    error_message = "worker_gdal_acr_sku must be one of Basic, Standard, Premium."
  }
}

# --- Storage (blob output staging) -----------------------------------------

variable "gp_output_container_name" {
  description = "Name of the blob container the GP tasks upload output to (surfaced as azure.storage.output_container_url to the server)."
  type        = string
  default     = "gp-output"
}

variable "storage_account_replication_type" {
  description = "Replication type for the GP output storage account (LRS/ZRS/GRS). LRS is the cost default; output is reproducible cert/demo data."
  type        = string
  default     = "LRS"
}

# --- Key Vault read grant (optional) ---------------------------------------

variable "gp_task_key_vault_id" {
  description = "Optional Key Vault resource id to grant the GP task identity read (Key Vault Secrets User) access to — e.g. the vault holding the DB connection string the GP container resolves. Empty disables the grant."
  type        = string
  default     = ""
}
