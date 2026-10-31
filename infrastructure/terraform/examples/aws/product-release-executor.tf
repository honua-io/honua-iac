variable "product_release_executor" {
  description = "Opt in the cell task role for the product release executor. Requires deployment_safety or deploy_control_plane. Leave false until the release session applies it. Do not point this cell at the standing update-rollback controller."
  type        = bool
  default     = false
}
