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

variable "location" {
  description = "Azure region."
  type        = string
  default     = "westus"
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}

variable "node_count" {
  description = "AKS system node count."
  type        = number
  default     = 2
}

variable "node_vm_size" {
  description = "AKS node VM size."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "node_os_disk_size_gb" {
  description = "Node OS disk size in GB."
  type        = number
  default     = 64
}

variable "auto_scaling_enabled" {
  description = "Enable cluster autoscaler on the default node pool."
  type        = bool
  default     = true
}

variable "node_min_count" {
  description = "Minimum node count when auto-scaling is enabled."
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum node count when auto-scaling is enabled."
  type        = number
  default     = 5
}

variable "kubernetes_version" {
  description = "Optional AKS version override."
  type        = string
  default     = ""
}

variable "sku_tier" {
  description = "AKS SKU tier."
  type        = string
  default     = "Free"
}

variable "authorized_ip_ranges" {
  description = "CIDR ranges allowed to access the AKS API endpoint when private_cluster_enabled is false."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.authorized_ip_ranges : can(cidrnetmask(cidr))])
    error_message = "authorized_ip_ranges must contain valid CIDR blocks."
  }
}

variable "local_account_disabled" {
  description = "Disable local Kubernetes admin accounts to avoid static kubeconfigs."
  type        = bool
  default     = true
}

variable "private_cluster_enabled" {
  description = "Provision AKS with a private API endpoint."
  type        = bool
  default     = true
}
