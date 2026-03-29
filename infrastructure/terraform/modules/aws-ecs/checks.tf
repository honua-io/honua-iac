check "existing_db_inputs" {
  assert {
    condition = (
      (var.existing_db_endpoint == "" && var.existing_db_connection_string == "") ||
      (var.existing_db_endpoint != "" && var.existing_db_connection_string != "")
    )
    error_message = "existing_db_endpoint and existing_db_connection_string must both be set or both be empty."
  }
}

check "existing_db_reuse_requires_cidrs" {
  assert {
    condition     = !local.db_use_existing || length(var.existing_db_cidrs) > 0
    error_message = "existing_db_cidrs must include at least one trusted CIDR when existing_db_endpoint is set."
  }
}

check "existing_db_admin_password_required" {
  assert {
    condition     = !(local.db_use_existing && var.enable_postgis) || var.existing_db_admin_password != "" || var.db_password != null
    error_message = "existing_db_admin_password or db_password must be set when enable_postgis is true on an existing database."
  }
}

check "existing_vpc_inputs" {
  assert {
    condition = (
      (var.existing_vpc_id == "" && var.existing_vpc_cidr == "" && length(var.existing_public_subnet_ids) == 0 && length(var.existing_private_subnet_ids) == 0) ||
      (var.existing_vpc_id != "" && var.existing_vpc_cidr != "" && length(var.existing_public_subnet_ids) > 0 && length(var.existing_private_subnet_ids) > 0)
    )
    error_message = "existing_vpc_id, existing_vpc_cidr, existing_public_subnet_ids, and existing_private_subnet_ids must be set together."
  }
}

check "existing_redis_inputs" {
  assert {
    condition     = var.redis_connection_string == "" || length(var.redis_connection_cidrs) > 0
    error_message = "redis_connection_cidrs must include at least one trusted CIDR when redis_connection_string is set."
  }
}

check "redis_reuse_is_exclusive" {
  assert {
    condition     = !(var.redis_enabled && trimspace(var.redis_connection_string) != "")
    error_message = "redis_enabled and redis_connection_string are mutually exclusive; set only one."
  }
}

check "ecs_scaling_bounds" {
  assert {
    condition = (
      (var.min_capacity != null ? var.max_capacity >= var.min_capacity : true) &&
      var.desired_count <= var.max_capacity &&
      (var.min_capacity != null ? var.desired_count >= var.min_capacity : true)
    )
    error_message = "desired_count, min_capacity, and max_capacity must satisfy min_capacity <= desired_count <= max_capacity."
  }
}

check "canary_weight_requires_canary" {
  assert {
    condition     = local.canary_enabled || var.canary_weight_percentage == 0
    error_message = "canary_weight_percentage must be 0 unless canary_enabled is true."
  }
}

check "canary_desired_count_when_enabled" {
  assert {
    condition     = !local.canary_enabled || var.canary_desired_count >= 1
    error_message = "canary_desired_count must be at least 1 when canary_enabled is true."
  }
}

check "nat_gateway_required" {
  assert {
    condition     = local.use_existing_vpc || var.enable_nat_gateway || var.assign_public_ip
    error_message = "Tasks in private subnets require either NAT gateway or public IP assignment for outbound connectivity."
  }
}

check "http_ingress_requires_https" {
  assert {
    condition     = local.use_https || !contains(local.http_ingress_cidrs, "0.0.0.0/0")
    error_message = "Public HTTP ingress over 0.0.0.0/0 requires HTTPS to be configured (set alb_certificate_arn or domain_name/route53_zone_id)."
  }
}

check "public_ingress_requires_https" {
  assert {
    condition     = !contains(concat(local.http_ingress_cidrs, local.https_ingress_cidrs), "0.0.0.0/0") || local.use_https
    error_message = "Public ingress (0.0.0.0/0) requires HTTPS to be configured."
  }
}
