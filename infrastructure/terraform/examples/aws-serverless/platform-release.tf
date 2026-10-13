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
