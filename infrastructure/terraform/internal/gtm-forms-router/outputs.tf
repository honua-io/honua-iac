output "function_url" {
  description = "Public endpoint for form submissions. POST to <url>contact, <url>waitlist, or <url>newsletter."
  value       = aws_lambda_function_url.forms_router.function_url
}

output "lambda_function_name" {
  description = "Name of the forms-router Lambda function."
  value       = aws_lambda_function.forms_router.function_name
}

output "attio_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Attio API key (value set out of band)."
  value       = aws_secretsmanager_secret.attio_api_key.arn
}

output "attio_secret_name" {
  description = "Name of the Secrets Manager secret holding the Attio API key."
  value       = aws_secretsmanager_secret.attio_api_key.name
}
