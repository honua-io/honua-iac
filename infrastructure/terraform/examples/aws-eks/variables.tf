variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Name prefix for resources."
  type        = string
  default     = "honua"
}

variable "environment" {
  description = "Environment suffix."
  type        = string
  default     = "it"
}

variable "tags" {
  description = "Additional tags."
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
  default     = ["10.40.101.0/24", "10.40.102.0/24", "10.40.103.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs."
  type        = list(string)
  default     = ["10.40.1.0/24", "10.40.2.0/24", "10.40.3.0/24"]
}

variable "cluster_version" {
  description = "EKS cluster version."
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "Managed node group instance types."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_cpu_architecture" {
  description = "CPU architecture for the managed node group. X86_64 is the release-certified default."
  type        = string
  default     = "X86_64"
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
  description = "Whether the identity creating the EKS cluster should receive admin permissions."
  type        = bool
  default     = false
}

variable "cluster_secret_encryption_enabled" {
  description = "Whether Kubernetes secrets are envelope-encrypted with a KMS CMK. Ephemeral parity cells set false (honua-release#127)."
  type        = bool
  default     = true
}

variable "cluster_secret_encryption_key_arn" {
  description = "Existing KMS CMK ARN to encrypt Kubernetes secrets with. Empty creates a module-managed key."
  type        = string
  default     = ""
}

# --- GA cell: workload identity and GP on Kubernetes ---------------------------

variable "workload_identity_mode" {
  description = "pod_identity (default; EKS Pod Identity, no IAM OIDC provider) or irsa (creates the cluster's IAM OIDC provider; service accounts need the role-arn annotation)."
  type        = string
  default     = "pod_identity"
}

variable "kubernetes_namespace" {
  description = "Namespace the Honua Helm release is installed into."
  type        = string
  default     = "honua"
}

variable "server_service_account_name" {
  description = "Service account the chart's server pods run as."
  type        = string
  default     = "honua"
}

variable "gp_job_namespace" {
  description = "Namespace for GP Kubernetes Jobs (ControlPlane:Kubernetes:DefaultNamespace). Empty uses kubernetes_namespace."
  type        = string
  default     = ""
}

variable "gp_job_service_account_name" {
  description = "Service account GP Jobs run as (ControlPlane:Kubernetes:DefaultServiceAccount)."
  type        = string
  default     = "honua-gp-job"
}

variable "gp_job_image" {
  description = "Image GP Kubernetes Jobs run (ControlPlane:Kubernetes:DefaultImage), pinned by digest. Empty leaves it to the chart/server default."
  type        = string
  default     = ""
}

variable "gp_job_data_bucket_arn" {
  description = "Optional S3 bucket ARN the GP job and server roles may read and write. Only used when gp_job_data_bucket_enabled is true."
  type        = string
  default     = ""
}

variable "gp_job_data_bucket_enabled" {
  description = "Grant the GP job and server roles S3 access to gp_job_data_bucket_arn. Set both together."
  type        = bool
  default     = false
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary for the server and GP job roles."
  type        = string
  default     = ""
}

# --- GA cell: runtime secrets ---------------------------------------------------

variable "honua_admin_password" {
  description = "Honua bootstrap admin password, stored in Secrets Manager. Null generates one."
  type        = string
  sensitive   = true
  default     = null
}

variable "honua_connection_encryption_master_key" {
  description = "Connection-encryption master key. Null generates one for a new deployment; existing deployments must set their current key."
  type        = string
  sensitive   = true
  default     = null
}

variable "secrets_kms_key_arn" {
  description = "Optional customer-managed KMS key for the module's Secrets Manager secrets. Empty uses aws/secretsmanager."
  type        = string
  default     = ""
}

variable "audit_chain_key_secret_kms_key_arn" {
  description = "Customer-managed KMS key ARN encrypting the audit-chain key secret. Leave empty for the AWS-managed aws/secretsmanager key."
  type        = string
  default     = ""
  nullable    = false
}

variable "audit_chain_key_secret_arn" {
  description = "ARN of an existing operator-owned Secrets Manager secret holding the base64 audit hash-chain key (at least 32 decoded bytes). Recommended for Production; the module validates the ARN. Never pass the key itself in tfvars."
  type        = string
  default     = ""
  nullable    = false
}

variable "operation_key_ring_certificate_secret_kms_key_arn" {
  description = "Customer-managed KMS key ARN encrypting the operation key-ring certificate secret. Leave empty for the AWS-managed aws/secretsmanager key. Granted only when Redis is enabled."
  type        = string
  default     = ""
  nullable    = false
}

variable "operation_key_ring_certificate_secret_arn" {
  description = "ARN of an existing operator-owned Secrets Manager secret containing base64 PKCS#12 or a JSON {pkcs12,password} bundle with a private key. Required when redis_enabled is true. Only the ARN enters Terraform."
  type        = string
  default     = ""
  nullable    = false
}

# --- GA cell: database ----------------------------------------------------------

variable "db_password" {
  description = "PostgreSQL master password. Null generates one."
  type        = string
  sensitive   = true
  default     = null
}

variable "existing_db_endpoint" {
  description = "Existing PostgreSQL endpoint to reuse instead of the managed RDS instance."
  type        = string
  default     = ""
}

variable "existing_db_connection_string" {
  description = "Existing PostgreSQL connection string to reuse."
  type        = string
  sensitive   = true
  default     = ""
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_publicly_accessible" {
  description = "Expose RDS publicly (validation cells only, for the runner-side PostGIS bootstrap)."
  type        = bool
  default     = false
}

variable "db_additional_ingress_cidrs" {
  description = "Extra CIDRs allowed to connect to Postgres."
  type        = list(string)
  default     = []
}

variable "rds_deletion_protection" {
  description = "Enable deletion protection on the managed RDS instance. Set false in a separate apply before destroy."
  type        = bool
  default     = true
}

variable "enable_postgis" {
  description = "Enable PostGIS and PostGIS Raster during apply. Requires psql on the Terraform runner and reach to the database endpoint."
  type        = bool
  default     = false
}

variable "postgis_readiness_max_attempts" {
  description = "Maximum readiness attempts before PostGIS enablement fails."
  type        = number
  default     = 90
}

variable "postgis_readiness_sleep_seconds" {
  description = "Seconds to sleep between PostgreSQL readiness attempts."
  type        = number
  default     = 10
}

# --- GA cell: Redis -------------------------------------------------------------

variable "enable_redis" {
  description = "Provision ElastiCache Redis (TLS + AUTH). Requires operation_key_ring_certificate_secret_arn. The ECS and Lambda roots spell this redis_enabled; the release harness passes whichever the pinned root declares."
  type        = bool
  default     = false
}

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

# --- GA cell: operation policy --------------------------------------------------

variable "operations_policy_rules" {
  description = "Ordered first-match-wins operation policy rules passed to the module and rendered as Operations__Policy__Rules__<n>__<Field>. The server runs in Production, where Operations:Policy denies every typed operation (for example service.publish) unless a rule allows it. decision is Allow, RequireApproval, DryRunFirst or Deny; operation_id defaults to \"*\". Empty (default) keeps the fail-closed default."
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
}

variable "cors_allowed_origins" {
  description = "Browser origins allowed to call the API (for example the Honua Console/Studio origin), rendered as Cors__AllowedOrigins__<n>. Empty (default) renders nothing; API-only cells need none."
  type        = list(string)
  default     = []
  nullable    = false
}

# --- GA cell: custom domain -----------------------------------------------------

variable "domain_name" {
  description = "Optional custom API hostname on any domain you own (for example gis.example.com) for the ACM-managed certificate and Route53 record."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID that owns domain_name."
  type        = string
  default     = ""
}

variable "public_base_url" {
  description = "Optional public origin for server-built absolute links (Public__BaseUrl), for example https://gis.example.com. Empty uses https://<domain_name> when the custom domain is configured. Must include the http(s) scheme."
  type        = string
  default     = ""
}

variable "subject_alternative_names" {
  description = "Subject alternative names for the ACM certificate."
  type        = list(string)
  default     = []
}

variable "ingress_load_balancer_hostname" {
  description = "DNS name of the chart's LoadBalancer Service, passed on a second apply so the module points domain_name at it. Empty creates no record."
  type        = string
  default     = ""
}
