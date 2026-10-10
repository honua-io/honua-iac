variable "name_prefix" {
  description = "Name prefix for resources."
  type        = string
  default     = "honua"
}

variable "environment" {
  description = "Environment suffix (dev, staging, prod, it)."
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Additional tags to apply to resources."
  type        = map(string)
  default     = {}
}

variable "vpc_cidr" {
  description = "CIDR for the EKS VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs."
  type        = list(string)
  default     = ["10.40.48.0/24", "10.40.49.0/24", "10.40.50.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs."
  type        = list(string)
  default     = ["10.40.0.0/20", "10.40.16.0/20", "10.40.32.0/20"]
}

variable "cluster_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "Managed node group instance types."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_cpu_architecture" {
  description = "CPU architecture for the managed node group. Use ARM64 for Graviton nodes or X86_64 for Intel/AMD nodes."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["ARM64", "X86_64"], upper(var.node_cpu_architecture))
    error_message = "node_cpu_architecture must be ARM64 or X86_64."
  }
}

variable "node_min_size" {
  description = "Minimum node group size."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum node group size."
  type        = number
  default     = 3
}

variable "node_desired_size" {
  description = "Desired node group size."
  type        = number
  default     = 2
}

variable "cluster_endpoint_public_access" {
  description = "Whether the EKS API server endpoint is publicly accessible."
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to access the EKS public endpoint."
  type        = list(string)
  default     = []
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Whether the identity creating the cluster should be automatically granted admin permissions."
  type        = bool
  default     = false
}

variable "cluster_addon_versions" {
  description = "Optional explicit EKS addon versions keyed by addon name (coredns, kube-proxy, vpc-cni)."
  type        = map(string)
  default     = {}
}

variable "cluster_secret_encryption_enabled" {
  description = "Whether Kubernetes secrets are envelope-encrypted with a KMS CMK. Production shape is true; ephemeral parity/validation clusters set false so a throwaway cluster does not strand a CMK on KMS's non-negotiable 7-day deletion window (honua-release#127)."
  type        = bool
  default     = true
}

variable "cluster_secret_encryption_key_arn" {
  description = "ARN of an existing KMS CMK to encrypt Kubernetes secrets with. Empty (the default) creates a module-managed key. Point ephemeral clusters at one long-lived key when the encryption path itself must stay under test without minting a key per cluster. Ignored when cluster_secret_encryption_enabled is false."
  type        = string
  default     = ""

  validation {
    condition     = var.cluster_secret_encryption_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:", var.cluster_secret_encryption_key_arn))
    error_message = "cluster_secret_encryption_key_arn must be empty or a KMS key ARN."
  }
}

# --- Workload identity ---------------------------------------------------------

variable "workload_identity_mode" {
  description = "How the Honua server and GP job pods receive AWS credentials. \"pod_identity\" (default) binds the module's IAM roles to their Kubernetes service accounts with EKS Pod Identity associations and installs the eks-pod-identity-agent add-on; it needs no account-level IAM OIDC provider. \"irsa\" creates the cluster's IAM OIDC provider and trusts it instead; the service accounts then need the eks.amazonaws.com/role-arn annotation from the *_service_account_annotations outputs."
  type        = string
  default     = "pod_identity"
  nullable    = false

  validation {
    condition     = contains(["pod_identity", "irsa"], var.workload_identity_mode)
    error_message = "workload_identity_mode must be pod_identity or irsa."
  }
}

variable "kubernetes_namespace" {
  description = "Namespace the Honua Helm release is installed into. The server role is bound to server_service_account_name in this namespace."
  type        = string
  default     = "honua"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.kubernetes_namespace))
    error_message = "kubernetes_namespace must be a valid Kubernetes namespace name."
  }
}

variable "server_service_account_name" {
  description = "Kubernetes service account the Honua server pods run as (the chart's serviceAccount.name; the chart defaults it to the release fullname, \"honua\" for a release named honua)."
  type        = string
  default     = "honua"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$", var.server_service_account_name))
    error_message = "server_service_account_name must be a valid Kubernetes service account name."
  }
}

variable "gp_job_namespace" {
  description = "Namespace GP Kubernetes Job runners are created in (ControlPlane:Kubernetes:DefaultNamespace). Empty uses kubernetes_namespace."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.gp_job_namespace == "" || can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.gp_job_namespace))
    error_message = "gp_job_namespace must be empty or a valid Kubernetes namespace name."
  }
}

variable "gp_job_service_account_name" {
  description = "Kubernetes service account GP Job pods run as (ControlPlane:Kubernetes:DefaultServiceAccount). The GP job role is bound to it in the GP job namespace."
  type        = string
  default     = "honua-gp-job"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$", var.gp_job_service_account_name))
    error_message = "gp_job_service_account_name must be a valid Kubernetes service account name."
  }
}

variable "gp_job_image" {
  description = "Container image GP Kubernetes Jobs run (ControlPlane:Kubernetes:DefaultImage), ideally pinned by digest. Empty leaves the setting out of the rendered environment so the chart or server default applies."
  type        = string
  default     = ""
  nullable    = false
}

variable "gp_job_data_bucket_arn" {
  description = "Optional S3 bucket ARN the GP job role (and the server role, which stages inputs and reads results) may read and write. Only used when gp_job_data_bucket_enabled is true."
  type        = string
  default     = ""
  nullable    = false
}

variable "gp_job_data_bucket_enabled" {
  description = "Grant the GP job and server roles S3 access to gp_job_data_bucket_arn. A separate plan-time-known flag because the ARN may be unknown until apply; set both together."
  type        = bool
  default     = false
  nullable    = false
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary attached to the server and GP job roles."
  type        = string
  default     = ""
  nullable    = false
}

# --- Database (RDS PostgreSQL + PostGIS) ----------------------------------------

variable "existing_db_endpoint" {
  description = "Existing PostgreSQL endpoint. Set together with existing_db_connection_string to skip the managed RDS instance."
  type        = string
  default     = ""
  nullable    = false
}

variable "existing_db_connection_string" {
  description = "Existing Npgsql connection string. Set together with existing_db_endpoint to skip the managed RDS instance."
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false
}

variable "db_username" {
  description = "Master username for the managed RDS instance."
  type        = string
  default     = "honua"
}

variable "db_password" {
  description = "Master password for the managed RDS instance. Null (default) generates one."
  type        = string
  default     = null
  sensitive   = true
}

variable "db_name" {
  description = "Database name on the managed RDS instance."
  type        = string
  default     = "honua"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GiB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Upper bound for RDS storage autoscaling in GiB."
  type        = number
  default     = 100
}

variable "db_engine_version" {
  description = "PostgreSQL engine version for the managed RDS instance."
  type        = string
  default     = "15"
}

variable "db_multi_az" {
  description = "Run the managed RDS instance Multi-AZ."
  type        = bool
  default     = false
}

variable "db_require_ssl" {
  description = "Append SSL Mode=Require to the generated connection string (the instance enforces rds.force_ssl either way)."
  type        = bool
  default     = true
}

variable "db_publicly_accessible" {
  description = "Place the managed RDS instance in the public subnets with a public address. Only for validation cells whose Terraform runner must reach it (enable_postgis); keep false in production."
  type        = bool
  default     = false
}

variable "db_additional_ingress_cidrs" {
  description = "Extra CIDRs allowed to reach PostgreSQL (for example the validation runner's /32 for the PostGIS bootstrap)."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "rds_deletion_protection" {
  description = "Enable deletion protection on the managed RDS instance. Ephemeral validation cells set false so terraform destroy can remove it."
  type        = bool
  default     = true
}

variable "enable_postgis" {
  description = "Enable PostGIS and PostGIS Raster on the managed database during apply via a local-exec psql bootstrap. Requires psql on the Terraform runner and network reach to the endpoint (db_publicly_accessible plus db_additional_ingress_cidrs)."
  type        = bool
  default     = false
}

variable "postgis_readiness_max_attempts" {
  description = "Maximum readiness attempts before PostGIS enablement fails."
  type        = number
  default     = 90

  validation {
    condition     = var.postgis_readiness_max_attempts >= 1
    error_message = "postgis_readiness_max_attempts must be at least 1."
  }
}

variable "postgis_readiness_sleep_seconds" {
  description = "Seconds to sleep between PostgreSQL readiness attempts."
  type        = number
  default     = 10

  validation {
    condition     = var.postgis_readiness_sleep_seconds >= 1
    error_message = "postgis_readiness_sleep_seconds must be at least 1."
  }
}

# --- Runtime secrets ------------------------------------------------------------

variable "admin_password" {
  description = "Honua bootstrap admin password, stored in Secrets Manager for the chart. Null (default) generates one."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.admin_password == null || length(coalesce(var.admin_password, "x")) >= 16
    error_message = "admin_password must be at least 16 characters."
  }
}

variable "connection_encryption_master_key" {
  description = "Honua connection-encryption master key (Security:ConnectionEncryption:MasterKey), stored in Secrets Manager. Null (default) generates one for a new deployment; an existing deployment must supply its current key."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.connection_encryption_master_key == null || length(coalesce(var.connection_encryption_master_key, "x")) >= 32
    error_message = "connection_encryption_master_key must be at least 32 characters."
  }
}

variable "secrets_kms_key_arn" {
  description = "Customer-managed KMS key ARN for the module's Secrets Manager secrets. Empty uses the AWS-managed aws/secretsmanager key, so an ephemeral cluster never strands a CMK in its 7-day deletion window."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.secrets_kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.secrets_kms_key_arn))
    error_message = "secrets_kms_key_arn must be an exact KMS key ARN or empty."
  }
}

variable "audit_chain_key_secret_kms_key_arn" {
  description = "Customer-managed KMS key ARN encrypting the audit-chain key secret. Leave empty for the AWS-managed aws/secretsmanager key."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.audit_chain_key_secret_kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.audit_chain_key_secret_kms_key_arn))
    error_message = "audit_chain_key_secret_kms_key_arn must be an exact KMS key ARN or empty."
  }
}

variable "audit_chain_key_secret_arn" {
  description = "ARN of an existing operator-owned Secrets Manager secret whose value is the base64 audit hash-chain key (at least 32 decoded bytes; AuditLog:ChainVerification:Key). Recommended for every Production deployment: without it audit rows are still written but scheduled chain verification never succeeds. Only the ARN enters Terraform; the server and GP job roles get read access and the rendered environment carries an aws:secretsmanager: reference."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.audit_chain_key_secret_arn == "" || can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.audit_chain_key_secret_arn))
    error_message = "audit_chain_key_secret_arn must be a complete Secrets Manager secret ARN (including its six-character suffix), not key material, a wildcard, or a JSON-key selector."
  }
}

variable "operation_key_ring_certificate_secret_kms_key_arn" {
  description = "Customer-managed KMS key ARN encrypting the operation key-ring certificate secret. Leave empty for the AWS-managed aws/secretsmanager key. Granted only when Redis is enabled."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.operation_key_ring_certificate_secret_kms_key_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.operation_key_ring_certificate_secret_kms_key_arn))
    error_message = "operation_key_ring_certificate_secret_kms_key_arn must be an exact KMS key ARN or empty."
  }
}

variable "operation_key_ring_certificate_secret_arn" {
  description = "ARN of an existing operator-owned Secrets Manager secret containing base64 PKCS#12 or a JSON {pkcs12,password} bundle with a private key. Required when redis_enabled is true. Only the ARN enters Terraform; the server and GP job roles get read access and the rendered environment carries an aws:secretsmanager: reference."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.operation_key_ring_certificate_secret_arn == "" || can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.operation_key_ring_certificate_secret_arn))
    error_message = "operation_key_ring_certificate_secret_arn must be a complete Secrets Manager secret ARN (including its six-character suffix), not PKCS#12 material, a wildcard, or a JSON-key selector."
  }
}

# --- Redis (ElastiCache) --------------------------------------------------------

variable "redis_enabled" {
  description = "Provision an ElastiCache Redis replication group (TLS in transit, encrypted at rest, AUTH token) reachable from the cluster nodes. Requires operation_key_ring_certificate_secret_arn. Off by default so existing callers keep planning without a key-ring secret."
  type        = bool
  default     = false
  nullable    = false
}

variable "redis_auth_token" {
  description = "Redis AUTH token. Empty (default) generates one. Must be 16-128 characters using letters, digits, or ElastiCache-supported special characters (!&#$^<>-)."
  type        = string
  default     = ""
  sensitive   = true
  nullable    = false

  validation {
    condition = var.redis_auth_token == "" || (
      length(var.redis_auth_token) >= 16 &&
      length(var.redis_auth_token) <= 128 &&
      can(regex("^[A-Za-z0-9!&#$^<>-]+$", var.redis_auth_token))
    )
    error_message = "redis_auth_token must be 16-128 characters and contain only letters, digits, or !&#$^<>-."
  }
}

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.0"
}

variable "redis_parameter_group_name" {
  description = "Redis parameter group name."
  type        = string
  default     = "default.redis7"
}

variable "redis_num_cache_clusters" {
  description = "Number of cache clusters in the replication group. Use 1 for lowest-cost validation; use >=2 for HA failover."
  type        = number
  default     = 1

  validation {
    condition     = var.redis_num_cache_clusters >= 1
    error_message = "redis_num_cache_clusters must be >= 1."
  }
}

variable "redis_port" {
  description = "Redis port."
  type        = number
  default     = 6379
}

# --- Operation policy -----------------------------------------------------------

variable "operations_policy_rules" {
  description = "Ordered first-match-wins operation policy rules, rendered as Operations__Policy__Rules__<n>__{OperationId,Role,Tier,Decision,Reason,ApprovalLane} into the honua_server_environment output for the chart. The server image runs in Production, where Operations:Policy is enabled with DefaultDecision Deny, so every typed operation (for example service.publish) is denied until a rule allows it. operation_id defaults to \"*\" (any operation, otherwise matched exactly); role and tier are optional case-insensitive filters; decision is Allow, RequireApproval, DryRunFirst or Deny. Empty (default) renders nothing and keeps the fail-closed default."
  type = list(object({
    operation_id  = optional(string, "*")
    role          = optional(string)
    tier          = optional(string)
    decision      = string
    reason        = optional(string)
    approval_lane = optional(string)
  }))
  default  = []
  nullable = false

  validation {
    condition     = alltrue([for rule in var.operations_policy_rules : contains(["Allow", "RequireApproval", "DryRunFirst", "Deny"], rule.decision)])
    error_message = "Each operations_policy_rules decision must be one of Allow, RequireApproval, DryRunFirst or Deny (the server's PolicyDecisionKind names)."
  }

  validation {
    condition     = alltrue([for rule in var.operations_policy_rules : rule.operation_id != null && trimspace(rule.operation_id) != ""])
    error_message = "operations_policy_rules operation_id must be an operation id or \"*\"; omit it to match any operation."
  }
}

# --- Custom domain (ACM + Route53) ----------------------------------------------

variable "domain_name" {
  description = "Optional public hostname for the Honua endpoint. With route53_zone_id, the module issues and DNS-validates an ACM certificate for it; the chart's LoadBalancer Service terminates TLS with that certificate (see the ingress_service_annotations output)."
  type        = string
  default     = ""
  nullable    = false
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID that owns domain_name."
  type        = string
  default     = ""
  nullable    = false
}

variable "subject_alternative_names" {
  description = "Subject alternative names for the ACM certificate."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "ingress_load_balancer_hostname" {
  description = "DNS name of the load balancer the Helm chart's Service created. The chart creates it after this module applies, so pass it on a second apply once it exists; the module then points domain_name at it with a Route53 CNAME it owns (and removes on destroy). Empty creates no record."
  type        = string
  default     = ""
  nullable    = false
}
