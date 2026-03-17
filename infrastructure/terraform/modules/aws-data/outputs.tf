// Pass through the canonical platform/component outputs.

output "vpc_id" {
  value = module.platform.vpc_id
}

output "vpc_cidr" {
  value = module.platform.vpc_cidr
}

output "public_subnet_ids" {
  value = module.platform.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.platform.private_subnet_ids
}

output "db_endpoint" {
  value = module.platform.db_endpoint
}

output "db_connection_string" {
  value = module.platform.db_connection_string
}

output "redis_connection_string" {
  value = module.platform.redis_connection_string
}

output "redis_primary_endpoint" {
  value = module.platform.redis_primary_endpoint
}
