# Database connection sizing for the API Lambda (README: Database connection
# sizing). The worst-case number of API processes is the function's reserved
# concurrency: every environment that can exist holds its pools while frozen.
# The control-plane event functions and GP Batch jobs keep their own fixed caps
# (control_plane_db_max_pool_size, gp_batch_db_max_pool_size) and are counted
# as other_connections, so the API pool is sized from what they leave.
#
# The API pool is derived only when RDS Proxy is off, the module manages the
# database (or db_max_connections_override is set) and
# lambda_reserved_concurrent_executions bounds the instances. Otherwise it
# stays at the previous fixed default of 8 (fallback), so a root that sets none
# of those inputs plans exactly as before. lambda_db_max_pool_size, when set,
# is the override.
#
# The Lambda functions carry only MaxConnectionPoolSize and MaxConcurrentQueries
# (4 KB environment budget, lambda_environment_limit_bytes); honua-server
# already defaults MinConnectionPoolSize to 0 on Lambda when it is unset.
locals {
  # serving_closed (honua-server#6750): reserved concurrency 0 on the API and
  # control-plane event functions until the database is migrated, so an early
  # request (an internet scanner on the API Gateway URL) cannot cold-start an
  # instance against an unmigrated schema. Pool sizing below always uses the
  # open values, so opening the deployment changes only reserved concurrency,
  # never a function environment or the connection string. A
  # lambda_reserved_concurrent_executions of 0 is a closed function too: it
  # bounds no open instances, so the API pool falls back as if unset.
  serving_reserved_concurrency = {
    api = var.serving_closed ? 0 : var.lambda_reserved_concurrent_executions
    control_plane = {
      for kind, value in local.control_plane_reserved_concurrency : kind => var.serving_closed ? 0 : value
    }
  }

  db_pool_control_plane_connections = local.control_plane_events_enabled ? (
    (local.control_plane_reserved_concurrency.reconcile + local.control_plane_reserved_concurrency.backstop + local.control_plane_reserved_concurrency.tick)
    * var.control_plane_db_max_pool_size * var.db_pools_per_process
  ) : 0
  db_pool_gp_batch_connections = local.gp_batch_enabled ? (
    floor(var.gp_batch_max_vcpus / local.gp_batch_default_vcpus) * var.gp_batch_db_max_pool_size * var.db_pools_per_process
  ) : 0

  db_pool_inputs = {
    engine                   = "rds-postgres"
    instance                 = var.db_instance_class
    external_database        = var.existing_db_endpoint != ""
    max_connections_override = var.db_max_connections_override
    max_processes            = var.lambda_reserved_concurrent_executions == 0 ? null : var.lambda_reserved_concurrent_executions
    pools_per_process        = var.db_pools_per_process
    other_connections        = local.db_pool_control_plane_connections + local.db_pool_gp_batch_connections
    safety_fraction          = var.db_connection_safety_fraction
    pool_size_override       = var.lambda_db_max_pool_size
    fallback_pool_size       = 8
    pooler_enabled           = var.enable_rds_proxy
    emit_min_pool_size       = false
    serverless               = true
  }
}

# ---- BEGIN shared db-pool-sizing ----
# This block is byte-identical in every deployment module that runs
# honua-server against PostgreSQL (aws-serverless, aws-ecs, aws-eks, azure-aca,
# azure-functions). tests/terraform/test_db_pool_sizing.py fails CI when the
# copies drift. Only local.db_pool_inputs, defined above this marker, differs
# per module. (Nested local modules are avoided on purpose: the aws-cert
# reviewed-module admission gate refuses module sources it has not reviewed.)
#
# honua-server sizes every Npgsql pool from Limits:Connections
# (PostgresDataSourceFactory), whose defaults are MaxConnectionPoolSize 200 and
# MinConnectionPoolSize 20 per pool. Each server process holds at least two
# pools on the same database: the main NpgsqlDataSource and the pool keyed by
# the data source's connection string that publish/import/migration paths open
# with `new NpgsqlConnection(connectionString)` (bound secure connections add
# one more per named source). Left at the default, a handful of processes
# exhausts a small database (PostgreSQL 53300).
#
#   usable           = max_connections - reserved
#   per_process_pool = floor((floor(usable * safety_fraction) - other_connections)
#                            / (max_processes * pools_per_process))
#   clamped to [1, 200 (server default)]
#
# MaxConcurrentQueries equals the pool (the server refuses to start when it is
# larger, LimitsOptionsValidator). Sizing needs a known max_connections (the
# tables below, or db_max_connections_override) and a known worst-case process
# count; without either the module keeps its previous value (fallback, or no
# keys and the server default) and the db_connection_budget output says so in
# its source field.
locals {
  # RDS for PostgreSQL default parameter group:
  #   max_connections = LEAST({DBInstanceClassMemory/9531392}, 5000)
  # https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Limits.html#RDS_Limits.MaxConnections
  # DBInstanceClassMemory is the instance memory less what the OS and RDS keep,
  # so it is below the nominal memory (observed: db.t3.micro 87, db.t4g.small
  # about 180, against 112 and 225 from nominal memory). The table uses 75% of
  # nominal memory as a deliberate lower bound; set db_max_connections_override
  # to the value `SHOW max_connections` reports, or when a custom parameter
  # group changes it. Aurora PostgreSQL is not provisioned by these modules.
  db_pool_rds_memory_gib_by_size = {
    burstable = { "micro" = 1, "small" = 2, "medium" = 4, "large" = 8, "xlarge" = 16, "2xlarge" = 32 }
    general   = { "large" = 8, "xlarge" = 16, "2xlarge" = 32, "4xlarge" = 64, "8xlarge" = 128, "12xlarge" = 192, "16xlarge" = 256 }
    memory    = { "large" = 16, "xlarge" = 32, "2xlarge" = 64, "4xlarge" = 128, "8xlarge" = 256, "12xlarge" = 384, "16xlarge" = 512 }
  }
  db_pool_rds_family_kind = {
    "t3" = "burstable", "t4g" = "burstable",
    "m5" = "general", "m6g" = "general", "m6i" = "general", "m7g" = "general", "m7i" = "general",
    "r5" = "memory", "r6g" = "memory", "r6i" = "memory", "r7g" = "memory", "r7i" = "memory",
  }
  db_pool_rds_class_parts = split(".", local.db_pool_inputs.instance)
  db_pool_rds_memory_gib = try(
    local.db_pool_rds_memory_gib_by_size[local.db_pool_rds_family_kind[local.db_pool_rds_class_parts[1]]][local.db_pool_rds_class_parts[2]],
    null,
  )
  db_pool_rds_max_connections = local.db_pool_rds_memory_gib == null ? null : min(floor(local.db_pool_rds_memory_gib * 1073741824 * 0.75 / 9531392), 5000)

  # Azure Database for PostgreSQL flexible server default max_connections by
  # compute; 15 are reserved for replication and monitoring.
  # https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-limits#maximum-connections
  db_pool_azure_burstable_max_connections = {
    "B1ms" = 50, "B2s" = 429, "B2ms" = 859, "B4ms" = 1718, "B8ms" = 3437, "B12ms" = 5000, "B16ms" = 5000, "B20ms" = 5000,
  }
  # General Purpose (D) and Memory Optimized (E) depend only on vCores.
  db_pool_azure_vcore_max_connections = {
    D = { "2" = 859, "4" = 1718, "8" = 3437 }
    E = { "2" = 1718, "4" = 3437 }
  }
  db_pool_azure_sku_parts = regexall("^(?:B|GP|MO)_Standard_(([BDE])([0-9]+)[a-z_0-9]*)$", local.db_pool_inputs.instance)
  db_pool_azure_max_connections = length(local.db_pool_azure_sku_parts) == 0 ? null : (
    local.db_pool_azure_sku_parts[0][1] == "B"
    ? lookup(local.db_pool_azure_burstable_max_connections, local.db_pool_azure_sku_parts[0][0], null)
    : try(lookup(local.db_pool_azure_vcore_max_connections[local.db_pool_azure_sku_parts[0][1]], local.db_pool_azure_sku_parts[0][2], 5000), null)
  )

  db_pool_max_connections = local.db_pool_inputs.max_connections_override != null ? local.db_pool_inputs.max_connections_override : (
    local.db_pool_inputs.external_database ? null : (
      local.db_pool_inputs.engine == "azure-flexible" ? local.db_pool_azure_max_connections : local.db_pool_rds_max_connections
    )
  )
  # RDS: superuser_reserved_connections 3 + rds.rds_superuser_reserved_connections 2.
  # Azure flexible server: 15 (see the URL above).
  db_pool_reserved_connections = local.db_pool_inputs.engine == "azure-flexible" ? 15 : 5
  db_pool_usable_connections   = local.db_pool_max_connections == null ? null : max(local.db_pool_max_connections - local.db_pool_reserved_connections, 0)

  db_pool_server_default_size = 200
  db_pool_sizable = (
    local.db_pool_usable_connections != null &&
    local.db_pool_inputs.max_processes != null &&
    !local.db_pool_inputs.pooler_enabled
  )
  db_pool_derived_size = local.db_pool_sizable ? min(max(floor(
    (floor(local.db_pool_usable_connections * local.db_pool_inputs.safety_fraction) - local.db_pool_inputs.other_connections)
    / (local.db_pool_inputs.max_processes * local.db_pool_inputs.pools_per_process)
  ), 1), local.db_pool_server_default_size) : null
  db_pool_size = local.db_pool_inputs.pool_size_override != null ? local.db_pool_inputs.pool_size_override : (
    local.db_pool_derived_size != null ? local.db_pool_derived_size : local.db_pool_inputs.fallback_pool_size
  )
  # Worst case: every process that can exist holds every pool full.
  db_pool_worst_case_connections = local.db_pool_size == null || local.db_pool_inputs.max_processes == null ? null : (
    local.db_pool_inputs.max_processes * local.db_pool_inputs.pools_per_process * local.db_pool_size + local.db_pool_inputs.other_connections
  )
  db_pool_fits = (
    local.db_pool_inputs.pooler_enabled ||
    local.db_pool_worst_case_connections == null ||
    local.db_pool_usable_connections == null ||
    try(local.db_pool_worst_case_connections <= local.db_pool_usable_connections, true)
  )
  db_pool_sizing_environment = local.db_pool_size == null ? {} : merge({
    Limits__Connections__MaxConnectionPoolSize = tostring(local.db_pool_size)
    Limits__Connections__MaxConcurrentQueries  = tostring(local.db_pool_size)
    }, local.db_pool_inputs.emit_min_pool_size ? {
    Limits__Connections__MinConnectionPoolSize = tostring(local.db_pool_inputs.serverless ? 0 : min(20, local.db_pool_size))
  } : {})
  db_pool_sizing = {
    max_connections        = local.db_pool_max_connections
    reserved_connections   = local.db_pool_reserved_connections
    usable_connections     = local.db_pool_usable_connections
    max_processes          = local.db_pool_inputs.max_processes
    pools_per_process      = local.db_pool_inputs.pools_per_process
    other_connections      = local.db_pool_inputs.other_connections
    safety_fraction        = local.db_pool_inputs.safety_fraction
    pool_size              = local.db_pool_size
    source                 = local.db_pool_inputs.pool_size_override != null ? "override" : (local.db_pool_derived_size != null ? "derived" : (local.db_pool_size != null ? "fallback" : "server-default"))
    worst_case_connections = local.db_pool_worst_case_connections
    pooler_enabled         = local.db_pool_inputs.pooler_enabled
  }
}

output "db_connection_budget" {
  description = "Database connection sizing: max_connections, reserved and usable connections, worst-case server processes, pools per process, other fixed connections, the per-process pool size and where it came from (derived, override, fallback or server-default), and the worst-case total."
  value       = local.db_pool_sizing

  precondition {
    condition     = local.db_pool_fits
    error_message = "Database connection budget exceeded: ${coalesce(local.db_pool_inputs.max_processes, 0)} processes x ${local.db_pool_inputs.pools_per_process} pools x ${coalesce(local.db_pool_size, 0)} connections + ${local.db_pool_inputs.other_connections} other = ${coalesce(local.db_pool_worst_case_connections, 0)}, above the ${coalesce(local.db_pool_usable_connections, 0)} usable connections (max_connections ${coalesce(local.db_pool_max_connections, 0)} less ${local.db_pool_reserved_connections} reserved). Lower the pool size override or the process ceiling, use a larger database, or put a connection pooler in front (see the README's Database connection sizing)."
  }
}
# ---- END shared db-pool-sizing ----
