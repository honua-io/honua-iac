variable "product_release_executor" {
  description = "Opt in the Lambda execution role for the product release executor. Leave false until the release session applies it. Do not point this function at the standing update-rollback controller."
  type        = bool
  default     = false
}
