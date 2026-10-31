variable "product_release_executor" {
  description = "Opt in the cert Lambda execution role for the product release executor. Leave false until the release session applies it. Cert cells must not use the standing update-rollback controller."
  type        = bool
  default     = false
}
