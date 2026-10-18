variable "enabled" {
  description = "Explicit opt-in to paid optional AgentCore resources. Disabled creates no resources."
  type        = bool
  default     = false
}

variable "name" {
  description = "Gateway name and IAM role prefix."
  type        = string
  default     = "honua-agentcore"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,39}$", var.name))
    error_message = "name must be 3-40 lowercase letters, digits or hyphens, beginning with a letter."
  }
}

variable "honua_base_url" {
  description = "Existing HTTPS Honua origin, including any deployment PathBase; no credentials, query or fragment."
  type        = string
  default     = null
  validation {
    condition     = var.honua_base_url == null ? true : can(regex("^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$", var.honua_base_url))
    error_message = "honua_base_url must be a credential-free HTTPS origin with an optional PathBase."
  }
}

variable "mcp_path" {
  description = "Canonical MCP path below the origin PathBase."
  type        = string
  default     = "/mcp"
  validation {
    condition     = contains(["/mcp", "/api/mcp"], var.mcp_path)
    error_message = "mcp_path must be an actual canonical Honua MCP route."
  }
}

variable "identity" {
  description = "Existing issuer and exact protected audience/scope/tenant/subjects. No issuer credentials are accepted or stored. Honua must independently validate the same delegated caller."
  type = object({
    discovery_url  = string
    issuer         = string
    audience       = string
    required_scope = string
    tenant_id      = string
    subjects       = set(string)
  })
  default = null
  validation {
    condition = var.identity == null ? true : (
      can(regex("^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$", var.identity.discovery_url)) &&
      can(regex("^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$", var.identity.issuer)) &&
      length(var.identity.audience) > 0 && length(var.identity.required_scope) > 0 &&
      can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", var.identity.tenant_id)) &&
      length(var.identity.subjects) > 0 && length(var.identity.subjects) <= 100 &&
      alltrue([for subject in var.identity.subjects : length(subject) > 0 && length(subject) <= 256])
    )
    error_message = "identity requires HTTPS discovery/issuer, audience, scope, a bounded tenant and explicit bounded subjects."
  }
}

variable "private_origin_resource_configuration_arn" {
  description = "Existing same-account/Region VPC Lattice resource configuration for the private Honua origin. This module does not create a public-backend bypass."
  type        = string
  default     = null
  validation {
    condition     = var.private_origin_resource_configuration_arn == null ? true : can(regex("^arn:[a-z-]+:vpc-lattice:[a-z0-9-]+:[0-9]{12}:resourceconfiguration/[A-Za-z0-9-]+$", var.private_origin_resource_configuration_arn))
    error_message = "Use an actual VPC Lattice resource-configuration ARN."
  }
}

variable "request_schema_json" {
  description = "Reviewed OpenAPI JSON describing exactly the canonical MCP HTTP path/request arguments for Policy. Actual engine schema/action compatibility must be qualified."
  type        = string
  default     = null
  validation {
    condition     = var.request_schema_json == null ? true : can(jsondecode(var.request_schema_json).openapi) && length(var.request_schema_json) <= 131072
    error_message = "request_schema_json must be bounded OpenAPI JSON."
  }
}

variable "cedar_policy_templates" {
  description = "Reviewed Cedar statements from Git. Literal __HONUA_GATEWAY_ARN__ is replaced with the actual gateway ARN. No natural-language policy generation or implicit broad permit."
  type        = map(string)
  default     = {}
  validation {
    condition = length(var.cedar_policy_templates) <= 100 && alltrue([
      for name, statement in var.cedar_policy_templates :
      can(regex("^[A-Za-z][A-Za-z0-9_]{0,39}$", name)) && length(statement) <= 16384 &&
      strcontains(statement, "__HONUA_GATEWAY_ARN__")
    ])
    error_message = "Each bounded named Cedar statement must explicitly bind __HONUA_GATEWAY_ARN__."
  }
}

variable "tags" {
  description = "Operator-owned resource tags."
  type        = map(string)
  default     = {}
}

variable "region" {
  description = "AWS Region for the optional gateway."
  type        = string
  default     = "us-west-2"
}
