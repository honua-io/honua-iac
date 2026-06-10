output "observe_role_definition_id" {
  description = "Resource ID of the read-only Honua support observe custom role. Use this to create PIM-eligible assignments or hand to Honua support tooling."
  value       = azurerm_role_definition.observe.role_definition_resource_id
}

output "break_glass_role_definition_id" {
  description = "Resource ID of the elevated Honua support break-glass custom role. Make Honua support principals PIM-eligible for this role; activation is per-ticket and time-bounded."
  value       = azurerm_role_definition.break_glass.role_definition_resource_id
}

output "scope" {
  description = "Azure scope the support-access roles are defined and assignable at."
  value       = var.scope
}

output "observe_assignment_principal_ids" {
  description = "Object IDs that received a standing observe (read-only) assignment, if any."
  value       = var.create_observe_assignment ? var.observe_principal_object_ids : []
}

output "break_glass_assignment_created" {
  description = "Whether a STANDING break-glass assignment was created (true) or break-glass is delivered via PIM eligibility instead (false, recommended)."
  value       = var.create_break_glass_assignment
}

# Ready-to-share manifest for Honua support tooling: role IDs, scope, and how
# elevation is delivered. No secrets are emitted.
output "support_access_manifest" {
  description = "Role definition IDs, scope, and activation model to hand to Honua support tooling."
  value = {
    scope = var.scope
    observe = {
      role_definition_id = azurerm_role_definition.observe.role_definition_resource_id
      access             = "read-only"
      assignment         = var.create_observe_assignment ? "standing" : "pim-eligible"
    }
    break_glass = {
      role_definition_id = azurerm_role_definition.break_glass.role_definition_resource_id
      access             = "short-lived-remediation"
      assignment         = var.create_break_glass_assignment ? "standing" : "pim-eligible"
      time_bounded_via   = var.create_break_glass_assignment ? "manual-revocation" : "entra-pim-activation"
    }
  }
}
