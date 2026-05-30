output "observe_role_arn" {
  description = "ARN of the read-only Honua support observe role. Provide this to Honua support tooling for diagnostics."
  value       = aws_iam_role.observe.arn
}

output "break_glass_role_arn" {
  description = "ARN of the short-lived elevated Honua support break-glass role. Provide this to Honua support tooling for approved remediation only."
  value       = aws_iam_role.break_glass.arn
}

output "break_glass_permissions_boundary_arn" {
  description = "ARN of the permissions boundary capping the break-glass role below admin."
  value       = aws_iam_policy.break_glass_boundary.arn
}

output "observe_max_session_duration" {
  description = "Maximum STS session duration (seconds) operators may request on the observe role."
  value       = aws_iam_role.observe.max_session_duration
}

output "break_glass_max_session_duration" {
  description = "Maximum STS session duration (seconds) operators may request on the break-glass role."
  value       = aws_iam_role.break_glass.max_session_duration
}

# Ready-to-share manifest for Honua support tooling: role ARNs plus the
# session constraints the operator workflow must honour. The ExternalId is a
# secret and is intentionally NOT emitted here.
output "support_access_manifest" {
  description = "Role ARNs and session constraints to hand to Honua support tooling (ExternalId excluded; share it out of band)."
  value = {
    observe = {
      role_arn             = aws_iam_role.observe.arn
      max_session_duration = aws_iam_role.observe.max_session_duration
      access               = "read-only"
    }
    break_glass = {
      role_arn             = aws_iam_role.break_glass.arn
      max_session_duration = aws_iam_role.break_glass.max_session_duration
      access               = "short-lived-remediation"
      requires_mfa         = var.require_mfa
    }
    requires_external_id  = true
    requires_session_tags = var.require_session_tags
    required_session_tags = var.require_session_tags ? ["HonuaTicketId", "HonuaOperator"] : []
  }
}
