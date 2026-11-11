output "allowed_ssh_cidrs" {
  description = "Validated SSH source CIDRs, sorted."
  value       = sort(tolist(var.allowed_ssh_cidrs))
}

output "ssh_public_key" {
  description = "Validated OpenSSH public key, trimmed."
  value       = trimspace(var.ssh_public_key)
}

output "budget_alert_email" {
  description = "Validated cost alert email."
  value       = var.budget_alert_email
}
