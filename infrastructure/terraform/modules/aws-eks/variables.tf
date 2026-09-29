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
