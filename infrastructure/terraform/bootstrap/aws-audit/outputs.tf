output "trail_name" {
  description = "Multi-Region management-event trail."
  value       = aws_cloudtrail.audit.name
}

output "audit_bucket" {
  description = "Bucket holding CloudTrail logs (cloudtrail/) and Config history and snapshots (config/)."
  value       = aws_s3_bucket.audit.id
}

output "alert_topic_arn" {
  description = "SNS topic for manual-change and stack-drift alerts."
  value       = aws_sns_topic.alerts.arn
}

output "alert_canary_parameter" {
  description = "Parameter to tag by hand when testing the alert path."
  value       = aws_ssm_parameter.alert_canary.name
}
