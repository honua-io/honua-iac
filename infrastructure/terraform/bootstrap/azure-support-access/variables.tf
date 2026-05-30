variable "name_prefix" {
  type        = string
  description = "Prefix applied to the support-access custom role names."
  default     = "Honua"
}

variable "scope" {
  type        = string
  description = <<-EOT
    Azure scope the support-access roles are defined and assignable at. Prefer a
    single resource group that holds the Honua deployment so support access can
    never reach unrelated resources. Must start with /subscriptions/. Example:
    /subscriptions/<sub-id>/resourceGroups/honua-prod.
  EOT

  validation {
    condition     = can(regex("^/subscriptions/[0-9a-fA-F-]+(/resourceGroups/.+)?$", var.scope))
    error_message = "scope must be a subscription or resource-group scope starting with /subscriptions/ (a resource-group scope is strongly recommended)."
  }
}

variable "observe_principal_object_ids" {
  type        = list(string)
  description = <<-EOT
    Entra (Azure AD) object IDs of the Honua support principals that receive the
    read-only observe role. These are the group/service-principal/user object IDs
    Honua support provides. At least one is required so the assignment is never
    left empty.
  EOT
  default     = []

  validation {
    condition     = alltrue([for id in var.observe_principal_object_ids : can(regex("^[0-9a-fA-F-]{36}$", id))])
    error_message = "Each observe principal must be an Entra object ID (a GUID), not a name or email."
  }
}

variable "break_glass_principal_object_ids" {
  type        = list(string)
  description = <<-EOT
    Entra (Azure AD) object IDs of the Honua support principals eligible for the
    elevated break-glass role. Whether these get a standing assignment or are made
    PIM-eligible (recommended) is controlled by create_break_glass_assignment.
  EOT
  default     = []

  validation {
    condition     = alltrue([for id in var.break_glass_principal_object_ids : can(regex("^[0-9a-fA-F-]{36}$", id))])
    error_message = "Each break-glass principal must be an Entra object ID (a GUID), not a name or email."
  }
}

variable "create_observe_assignment" {
  type        = bool
  description = <<-EOT
    Create the role assignment(s) for the observe role. Read-only diagnostics are
    safe to grant as a standing assignment, so this defaults to true. Set false if
    you instead make the observe role PIM-eligible and activate per ticket.
  EOT
  default     = true
}

variable "create_break_glass_assignment" {
  type        = bool
  description = <<-EOT
    Create a STANDING role assignment for the break-glass role. This defaults to
    FALSE because elevated remediation access must be time-bounded: the
    recommended pattern is to make break_glass_principal_object_ids PIM-eligible
    for the break-glass role (an operational step Terraform cannot fully
    provision) so activation is per-ticket and auto-expires. Set true only if your
    tenant lacks Entra PIM and you accept a standing elevated assignment that you
    revoke manually after each incident.
  EOT
  default     = false
}

variable "principal_type" {
  type        = string
  description = <<-EOT
    The type of principal in *_principal_object_ids. One of Group (recommended),
    ServicePrincipal, or User. Using a Group lets Honua manage membership without
    re-applying Terraform.
  EOT
  default     = "Group"

  validation {
    condition     = contains(["Group", "ServicePrincipal", "User"], var.principal_type)
    error_message = "principal_type must be one of Group, ServicePrincipal, or User."
  }
}
