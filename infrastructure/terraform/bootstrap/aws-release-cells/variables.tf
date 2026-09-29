variable "region" {
  description = "Only region where certification cells may operate."
  type        = string
  default     = "us-east-1"
}
variable "name" {
  description = "Operator-owned role namespace, outside honuar*, honuan*, and honuaeks*."
  type        = string
  default     = "honua-release-cell"
  validation {
    condition     = can(regex("^honua-release-[a-z0-9-]+$", var.name))
    error_message = "Keep the bootstrap outside the agent-managed cell namespaces."
  }
}
variable "oidc_provider_arn" {
  description = "Existing GitHub OIDC provider; only the operator can change it."
  type        = string
}
variable "oidc_subjects" {
  description = "Exact GitHub environment subjects. Protect these three environments separately."
  type        = map(string)
  default = {
    provision = "repo:honua-io/honua-release:environment:aws-cell-provision"
    reaper    = "repo:honua-io/honua-release:environment:aws-cell-reaper"
    mirror    = "repo:honua-io/honua-release:environment:aws-cell-mirror"
  }
  validation {
    condition     = alltrue([for lane in ["provision", "reaper", "mirror"] : can(regex("^repo:honua-io/[A-Za-z0-9_.-]+:environment:[A-Za-z0-9_-]+$", var.oidc_subjects[lane]))]) && length(distinct(values(var.oidc_subjects))) == 3
    error_message = "Each lane needs a distinct, exact GitHub environment subject (no wildcard)."
  }
}
variable "mirror_repository_arn" {
  description = "Single existing operator-owned ECR mirror repository."
  type        = string
}
