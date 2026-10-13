variable "platform_release" {
  description = "Optional declared platform release identity. Use the signed release version and digest-pinned artifacts; null preserves existing environment configuration."
  type = object({
    version                    = string
    serving_artifact_reference = string
    workers = optional(list(object({
      runtime_profile    = optional(string)
      artifact_reference = string
    })), [])
  })
  default = null

  validation {
    condition = var.platform_release == null ? true : (
      length(trimspace(var.platform_release.version)) > 0 &&
      can(regex("^.+@sha256:[0-9a-f]{64}$", var.platform_release.serving_artifact_reference)) &&
      alltrue([for worker in var.platform_release.workers : can(regex("^.+@sha256:[0-9a-f]{64}$", worker.artifact_reference))])
    )
    error_message = "platform_release requires a nonempty version and digest-pinned serving and worker artifacts."
  }
}

# A staged canary can declare the candidate while the primary retains the prior release.
variable "canary_platform_release" {
  description = "Optional canary release identity. Null inherits platform_release; when both are null, existing raw environment configuration is preserved."
  type = object({
    version                    = string
    serving_artifact_reference = string
    workers = optional(list(object({
      runtime_profile    = optional(string)
      artifact_reference = string
    })), [])
  })
  default = null

  validation {
    condition = var.canary_platform_release == null ? true : (
      length(trimspace(var.canary_platform_release.version)) > 0 &&
      can(regex("^.+@sha256:[0-9a-f]{64}$", var.canary_platform_release.serving_artifact_reference)) &&
      alltrue([for worker in var.canary_platform_release.workers : can(regex("^.+@sha256:[0-9a-f]{64}$", worker.artifact_reference))])
    )
    error_message = "canary_platform_release requires a nonempty version and digest-pinned serving and worker artifacts."
  }
}
