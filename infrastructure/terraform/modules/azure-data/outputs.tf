// Pass through the canonical platform/component outputs.

output "db_fqdn" {
  value = module.platform.db_fqdn
}

output "db_connection_string" {
  value = module.platform.db_connection_string
}

output "redis_connection_string" {
  value = module.platform.redis_connection_string
}

output "key_vault_id" {
  value = module.platform.key_vault_id
}

output "key_vault_name" {
  value = module.platform.key_vault_name
}

output "db_connection_secret_id" {
  value = module.platform.db_connection_secret_id
}

output "admin_password_secret_id" {
  value = module.platform.admin_password_secret_id
}

output "redis_connection_secret_id" {
  value = module.platform.redis_connection_secret_id
}

output "resource_group_name" {
  value = module.platform.resource_group_name
}
