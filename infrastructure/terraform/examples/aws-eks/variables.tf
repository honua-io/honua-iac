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
  default     = ["t4g.small"]
}

variable "node_cpu_architecture" {
  description = "CPU architecture for the managed node group."
  type        = string
  default     = "ARM64"
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
