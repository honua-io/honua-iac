variable "name_prefix" {
  description = "Name prefix for resources."
  type        = string
  default     = "honua"
}

variable "environment" {
  description = "Environment suffix."
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "westus"
}

variable "tags" {
  description = "Additional tags to apply."
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
  description = "OS disk size for AKS nodes."
  type        = number
  default     = 64
}

variable "kubernetes_version" {
  description = "Optional AKS Kubernetes version."
  type        = string
  default     = ""
}

variable "sku_tier" {
  description = "AKS SKU tier."
  type        = string
  default     = "Free"
}

variable "authorized_ip_ranges" {
  description = "Authorized API server CIDR ranges."
  type        = list(string)
  default     = []
}

variable "grant_current_principal_cluster_admin" {
  description = "Grant the current Terraform principal AKS cluster admin rights."
  type        = bool
  default     = false
}

variable "acr_resource_id" {
  description = "Optional ACR resource ID to grant AcrPull to the AKS kubelet identity."
  type        = string
  default     = ""
}
