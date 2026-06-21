output "honua_url" {
  description = "Convenience URL for the deployed Honua service."
  value       = module.honua.service_url
}

output "db_endpoint" {
  description = "RDS PostgreSQL endpoint."
  value       = module.honua.db_endpoint
}
