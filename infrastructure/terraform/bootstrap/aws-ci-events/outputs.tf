output "function_url" {
  description = "Payload URL for the GitHub organisation webhook."
  value       = aws_lambda_function_url.receiver.function_url
}

output "queue_url" {
  description = "Queue the lane host's ci-dispatch long-polls (write it to handoffs/grok-eval5/ci-events/queue-url there)."
  value       = aws_sqs_queue.events.url
}

output "queue_arn" {
  description = "Pass to bootstrap/aws-lane-host as ci_events_queue_arn to let the lane host receive and delete."
  value       = aws_sqs_queue.events.arn
}

output "dead_letter_queue_url" {
  description = "Messages ci-dispatch failed to process five times."
  value       = aws_sqs_queue.dead_letter.url
}
