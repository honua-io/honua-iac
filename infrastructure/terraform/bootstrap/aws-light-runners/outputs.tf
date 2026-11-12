output "autoscaling_group_name" {
  description = "Desired capacity one runs the pool; zero stops it."
  value       = aws_autoscaling_group.runners.name
}

output "heartbeat_parameter" {
  description = "Readiness the host publishes every 30 seconds: instance, epoch seconds and idle runners."
  value       = aws_ssm_parameter.heartbeat.name
}
