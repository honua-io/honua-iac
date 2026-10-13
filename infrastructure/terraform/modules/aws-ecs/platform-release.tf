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

locals {
  platform_releases = {
    primary = var.platform_release
    canary  = var.canary_platform_release == null ? var.platform_release : var.canary_platform_release
  }
  platform_release_environment = {
    for slot, release in local.platform_releases : slot => release == null ? {} : merge({
      ControlPlane__PlatformRelease__Version                  = release.version
      ControlPlane__PlatformRelease__ServingArtifactReference = release.serving_artifact_reference
      }, merge({}, [for index, worker in release.workers : merge({
        "ControlPlane__PlatformRelease__Workers__${index}__ArtifactReference" = worker.artifact_reference
        }, worker.runtime_profile == null ? {} : {
        "ControlPlane__PlatformRelease__Workers__${index}__RuntimeProfile" = worker.runtime_profile
      })]...)
    )
  }
}

output "platform_release_environment" {
  description = "Declared non-secret release identity rendered into each serving slot. Empty maps mean no typed identity was supplied."
  value       = local.platform_release_environment
}
