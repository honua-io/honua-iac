output "controller_role_arn" {
  description = "Set as honua-release variable HONUA_UPDATE_ROLLBACK_CONTROLLER_ROLE_ARN."
  value       = aws_iam_role.controller.arn
}

output "controller_role_name" {
  description = "HONUA_UPDATE_ROLLBACK_ECS_SAFETY.controller_role_name (examples/aws deployment_safety)."
  value       = aws_iam_role.controller.name
}
