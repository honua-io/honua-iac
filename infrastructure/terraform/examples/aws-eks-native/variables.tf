variable "region" {
  type        = string
  description = "AWS region of the existing EKS cluster."
}

variable "cluster_name" {
  type        = string
  description = "Existing EKS cluster from the governed aws-eks infrastructure root."
}

variable "environment" {
  type        = string
  description = "Deployment environment."
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}$", var.environment))
    error_message = "environment must be a nonempty lowercase environment identifier."
  }
}

variable "target_id" {
  type        = string
  description = "Stable deployment target ID authorized by the exact-plan lane."
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.target_id))
    error_message = "target_id must be a nonempty lowercase Kubernetes label value (at most 63 characters)."
  }
}

variable "tenant_id" {
  type        = string
  description = "Tenant identifier to bind to the install handoff. This is an identity pin, not a tenant credential."
  validation {
    condition     = trimspace(var.tenant_id) != ""
    error_message = "tenant_id must identify the intended tenant."
  }
}

variable "image_reference" {
  type        = string
  description = "Immutable Honua server image, fully qualified with @sha256:<digest>."
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*(\\.[A-Za-z0-9._-]+)*(:[0-9]+)?(/[A-Za-z0-9._-]+)+@sha256:[0-9a-f]{64}$", var.image_reference))
    error_message = "image_reference must be a fully qualified OCI image pinned by sha256 digest."
  }
}

variable "gp_job_image_reference" {
  type        = string
  description = "Immutable GP Job image; must be supported for the selected workload credential provider."
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*(\\.[A-Za-z0-9._-]+)*(:[0-9]+)?(/[A-Za-z0-9._-]+)+@sha256:[0-9a-f]{64}$", var.gp_job_image_reference))
    error_message = "gp_job_image_reference must be a fully qualified OCI image pinned by sha256 digest."
  }
}

variable "artifact_capabilities" {
  type = object({
    server_image_digest           = string
    gp_job_image_digest           = string
    supported_workload_identities = set(string)
  })
  description = "Capabilities from the reviewed artifact manifest. Must match both installed immutable image digests and include the selected workload identity mode."
  validation {
    condition = (can(regex("^sha256:[0-9a-f]{64}$", var.artifact_capabilities.server_image_digest)) &&
      can(regex("^sha256:[0-9a-f]{64}$", var.artifact_capabilities.gp_job_image_digest)) &&
    alltrue([for mode in var.artifact_capabilities.supported_workload_identities : contains(["pod_identity", "irsa"], mode)]))
    error_message = "artifact_capabilities must contain SHA-256 image digests and supported identity modes."
  }
}

variable "namespace" {
  type    = string
  default = "honua"
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a DNS label."
  }
}

variable "deployment_name" {
  type    = string
  default = "honua"
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,54}[a-z0-9])?$", var.deployment_name))
    error_message = "deployment_name must be a DNS label of at most 56 characters so the public Service name also fits."
  }
}

variable "container_name" {
  type    = string
  default = "honua"
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.container_name))
    error_message = "container_name must be a DNS label."
  }
}

variable "server_service_account_name" {
  type    = string
  default = "honua"
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.server_service_account_name))
    error_message = "server_service_account_name must be a DNS label."
  }
}

variable "gp_job_service_account_name" {
  type    = string
  default = "honua-gp-job"
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.gp_job_service_account_name))
    error_message = "gp_job_service_account_name must be a DNS label."
  }
}

variable "server_role_arn" {
  type        = string
  description = "Server Pod Identity or IRSA role ARN from the existing aws-eks infrastructure root."
}

variable "gp_job_role_arn" {
  type        = string
  description = "Separate GP Job Pod Identity or IRSA role ARN from the existing aws-eks infrastructure root."
}

variable "workload_identity_mode" {
  type    = string
  default = "pod_identity"
  validation {
    condition     = var.workload_identity_mode == "pod_identity"
    error_message = "The native install resolves Secrets Manager references through EKS Pod Identity; IRSA is not supported by this server credential resolver."
  }
}

variable "server_pod_identity_association_id" {
  type        = string
  description = "Existing server association ID from the aws-eks infrastructure root."
  validation {
    condition     = can(regex("^a-[a-z0-9]+$", var.server_pod_identity_association_id))
    error_message = "server_pod_identity_association_id must identify an existing EKS association."
  }
}

variable "gp_job_pod_identity_association_id" {
  type        = string
  description = "Existing GP Job association ID from the aws-eks infrastructure root."
  validation {
    condition     = can(regex("^a-[a-z0-9]+$", var.gp_job_pod_identity_association_id))
    error_message = "gp_job_pod_identity_association_id must identify an existing EKS association."
  }
}

variable "db_connection_secret_arn" {
  type        = string
  description = "Database connection secret ARN from the existing aws-eks infrastructure root."
}

variable "admin_password_secret_arn" {
  type        = string
  description = "Admin password secret ARN from the existing aws-eks infrastructure root."
}

variable "master_key_secret_arn" {
  type        = string
  description = "Connection-encryption master key secret ARN from the existing aws-eks infrastructure root."
}

variable "redis_connection_secret_arn" {
  type        = string
  default     = ""
  description = "Optional Redis connection secret ARN."
}

variable "operation_key_ring_certificate_secret_arn" {
  type        = string
  default     = ""
  description = "Optional operator-owned key-ring certificate secret ARN."
}

variable "audit_chain_key_secret_arn" {
  type        = string
  default     = ""
  description = "Optional operator-owned audit-chain key secret ARN."
}

variable "public_hostname" {
  type        = string
  description = "Public DNS hostname on the ACM certificate. The verifier must later observe the route."
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.public_hostname)) && length(var.public_hostname) <= 253
    error_message = "public_hostname must be a DNS hostname."
  }
}

variable "certificate_arn" {
  type        = string
  description = "Validated ACM certificate ARN covering public_hostname."
  validation {
    condition     = can(regex("^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/[a-f0-9-]+$", var.certificate_arn))
    error_message = "certificate_arn must be an ACM certificate ARN."
  }
}

variable "route53_zone_id" {
  type        = string
  default     = ""
  description = "Route53 hosted zone to manage a CNAME for public_hostname. Empty means external DNS ownership."
  validation {
    condition     = var.route53_zone_id == "" || can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must be empty or a Route53 hosted zone ID."
  }
}

variable "load_balancer_controller" {
  type        = string
  description = "Explicit existing controller capability: legacy-service-controller or aws-load-balancer-controller."
  validation {
    condition     = contains(["legacy-service-controller", "aws-load-balancer-controller"], var.load_balancer_controller)
    error_message = "Select an existing EKS load balancer capability explicitly."
  }
}

variable "replicas" {
  type    = number
  default = 2
  validation {
    condition     = var.replicas >= 1 && var.replicas <= 100 && floor(var.replicas) == var.replicas
    error_message = "replicas must be an integer between 1 and 100."
  }
}

variable "mcp_validation" {
  type = object({
    enabled        = optional(bool, false)
    profile        = optional(string)
    transport      = optional(string)
    path           = optional(string)
    required_tools = optional(list(string), [])
  })
  default = {}
  validation {
    condition = !var.mcp_validation.enabled ? true : (
      try(trimspace(var.mcp_validation.profile) != "", false) &&
      contains(["http", "stdio"], var.mcp_validation.transport) &&
      can(regex("^/", var.mcp_validation.path)) &&
      length(var.mcp_validation.required_tools) > 0
    )
    error_message = "MCP validation requires profile, transport, absolute path and required tools when enabled."
  }
}
