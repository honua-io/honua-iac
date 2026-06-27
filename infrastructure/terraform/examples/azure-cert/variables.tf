###############################################################################
# Inputs for the Azure real-cloud certification tier (examples/azure-cert).
#
# Parallel to examples/aws-cert: a Honua-owned stack that certifies the
# GP-over-Azure-Batch path against REAL Azure, with GitHub-OIDC federation so a
# dispatched cert workflow can terraform apply / drive Batch with NO client
# secret.
###############################################################################

variable "location" {
  description = "Azure region for the certification stack."
  type        = string
  default     = "eastus"
}

variable "name_prefix" {
  description = "Prefix used for resource names. Combined with environment yields the honua-cert-* surface."
  type        = string
  default     = "honua-cert"
}

variable "environment" {
  description = "Environment name. 'cert' yields honua-cert-cert-* resources."
  type        = string
  default     = "cert"
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}

# --- GP Batch substrate (forwarded to modules/azure-gp) --------------------
# Only substrate-level inputs live here. Per-job sizing (command line, retry,
# timeout, env) is a runtime SubmitTask parameter applied by the server — NOT a
# terraform variable — so there are intentionally no per-job knobs.

variable "gp_pool_vm_size" {
  description = "VM size for the single GP Batch pool (Azure sizes per-pool)."
  type        = string
  default     = "Standard_D4s_v3"
}

variable "gp_pool_use_low_priority" {
  description = "Use low-priority (Spot) nodes for the cert GP pool (cheaper; preemptible). See the azure-gp module README for the preemption note."
  type        = bool
  default     = true
}

variable "gp_pool_max_nodes" {
  description = "Autoscale node ceiling for the cert GP pool."
  type        = number
  default     = 2
}

variable "create_worker_gdal_acr" {
  description = "Create the dedicated worker-gdal ACR for the cert GP worker image."
  type        = bool
  default     = true
}

variable "worker_gdal_acr_sku" {
  description = "SKU for the cert worker-gdal ACR."
  type        = string
  default     = "Standard"
}

# --- GitHub OIDC federation (inline azurerm_federated_identity_credential) --

variable "github_oidc_subject" {
  description = "OIDC `sub` claim the cert identity trusts. Pin to a GitHub Environment for the tightest scope, e.g. repo:honua-io/honua-server:environment:cert."
  type        = string
  default     = "repo:honua-io/honua-server:environment:cert"

  validation {
    condition     = trimspace(var.github_oidc_subject) != ""
    error_message = "github_oidc_subject must be a non-empty GitHub OIDC subject (e.g. repo:owner/repo:environment:cert)."
  }
}
