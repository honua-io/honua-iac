###############################################################################
# Inputs for the seeded cloud-demo smoke credential store (honua-iac#30).
#
# Secret VALUES are NOT defined here. This component provisions the Key Vault,
# the smoke managed identity, the access policy, and the secret SLOTS, plus the
# OIDC federation that lets the scheduled GitHub Actions smoke read them. The
# operator supplies secret material out-of-band (see README.md "Operator steps")
# so no credential is ever committed to Terraform state inputs in the repo.
###############################################################################

variable "name_prefix" {
  description = "Name prefix for resources."
  type        = string
  default     = "honua-clouddemo"
}

variable "environment" {
  description = "Environment name (staging is the seeded cloud demo tenant per honua-sdk-js#128)."
  type        = string
  default     = "staging"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "eastus"
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Key Vault hardening. Defaults are fail-safe (no public network, RBAC-able);
# the operator opens only what the runner needs (its egress IP / OIDC subject).
# ---------------------------------------------------------------------------

variable "key_vault_purge_protection_enabled" {
  description = "Enable Key Vault purge protection. Recommended true for credential stores."
  type        = bool
  default     = true
}

variable "key_vault_soft_delete_retention_days" {
  description = "Soft-delete retention window for the Key Vault."
  type        = number
  default     = 7
}

variable "key_vault_public_network_access_enabled" {
  description = "Whether the Key Vault data plane is reachable from public networks. Hosted GitHub runners need this true (or a self-hosted runner inside the vnet)."
  type        = bool
  default     = true
}

variable "key_vault_default_action" {
  description = "Network ACL default action. Keep Deny and allowlist the runner egress in key_vault_ip_rules."
  type        = string
  default     = "Deny"
}

variable "key_vault_bypass" {
  description = "Key Vault network ACL bypass. AzureServices lets first-party services reach the vault."
  type        = string
  default     = "AzureServices"
}

variable "key_vault_ip_rules" {
  description = "CIDRs allowed to reach the Key Vault data plane (the smoke runner egress). Empty + Deny means only AzureServices bypass applies."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# OIDC federation for the scheduled GitHub Actions smoke.
# The smoke logs in to Azure with azure/login@v2 (federated, NO client secret)
# and reads the demo credentials from this vault, then exports them as the
# HONUA_CLOUD_DEMO_* env the merged .github/workflows/cloud-demo-smoke.yml uses.
# ---------------------------------------------------------------------------

variable "github_owner" {
  description = "GitHub org/owner that runs the scheduled smoke workflow."
  type        = string
  default     = "honua-io"
}

variable "github_repository" {
  description = "GitHub repository (without owner) hosting the scheduled smoke workflow."
  type        = string
  default     = "honua-iac"
}

variable "github_oidc_subject" {
  description = <<-EOT
    Exact OIDC subject claim the federated credential trusts. For a scheduled
    workflow on the default branch this is typically
    "repo:<owner>/<repo>:ref:refs/heads/trunk". Pin it to the branch/environment
    the smoke actually runs from so a fork PR cannot assume the identity.
  EOT
  type        = string
  default     = "repo:honua-io/honua-iac:ref:refs/heads/trunk"
}

# ---------------------------------------------------------------------------
# Seeded service wiring that the smoke needs but that is NOT secret. These map
# 1:1 onto honua-sdk-js/examples/cloud-demo-services.json globalEnv / profiles.
# ---------------------------------------------------------------------------

variable "cloud_demo_base_url" {
  description = "Public base URL of the seeded Honua Cloud demo API (HONUA_CLOUD_DEMO_BASE_URL)."
  type        = string
  default     = "https://cloud.honua.io"
}

variable "cloud_demo_stream_url" {
  description = "Realtime incident SSE stream URL for the seeded demo (VITE_HONUA_INCIDENT_STREAM_URL). Not secret, but stored alongside for one-stop smoke wiring."
  type        = string
  default     = "https://cloud.honua.io/api/v1/realtime/incidents/sse"
}

variable "cloud_demo_metadata_ttl_ms" {
  description = "Metadata cache TTL the smoke advertises (HONUA_CLOUD_DEMO_METADATA_TTL_MS)."
  type        = number
  default     = 900000
}

variable "cloud_demo_reset_url" {
  description = <<-EOT
    Server-side reset endpoint for the disposable writable seeded service. Used
    ONLY by the server-side smoke/deployment jobs, never exposed to browser
    VITE_* vars (REQ-004). Leave empty until the writable lane is enabled.
  EOT
  type        = string
  default     = ""
}

variable "enable_writable_lane" {
  description = <<-EOT
    Provision the write/reset secret slots for the guarded writable smoke.
    NFR-001: the writable seeded service must fail closed — when this is false,
    no write/reset slots exist and HONUA_CLOUD_DEMO_ALLOW_WRITES must stay false.
  EOT
  type        = bool
  default     = false
}
