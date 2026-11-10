variable "postgis_bootstrap_image" {
  description = "Optional immutable PostgreSQL client image (psql entrypoint) for in-VPC PostGIS initialization before every server/migrator start. Null preserves the runner-based enable_postgis behavior."
  type        = string
  default     = null
  validation {
    condition     = var.postgis_bootstrap_image == null ? true : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]+)?(/[A-Za-z0-9._-]+)+@sha256:[0-9a-f]{64}$", var.postgis_bootstrap_image))
    error_message = "postgis_bootstrap_image must be an immutable registry/repository@sha256 digest."
  }
}

locals {
  postgis_bootstrap_dependencies = var.postgis_bootstrap_image == null ? [] : [{ containerName = "postgis", condition = "SUCCESS" }]
  postgis_bootstrap_containers = var.postgis_bootstrap_image == null ? [] : [{
    name       = "postgis"
    image      = var.postgis_bootstrap_image
    essential  = false
    entryPoint = ["psql"]
    command    = ["--no-psqlrc", "--set=ON_ERROR_STOP=1", "--command", "SELECT pg_advisory_lock(721306291); CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS postgis_raster; SELECT pg_advisory_unlock(721306291);"]
    environment = [
      { name = "PGHOST", value = local.db_endpoint },
      { name = "PGPORT", value = "5432" },
      { name = "PGDATABASE", value = var.db_name },
      { name = "PGUSER", value = var.db_username },
      { name = "PGSSLMODE", value = "require" },
      { name = "PGCONNECT_TIMEOUT", value = "30" }
    ]
    secrets          = [{ name = "PGPASSWORD", valueFrom = aws_secretsmanager_secret.postgis_password[0].arn }]
    logConfiguration = local.container_log_configuration
  }]
}

resource "terraform_data" "postgis_bootstrap_validation" {
  lifecycle {
    precondition {
      condition     = var.postgis_bootstrap_image == null || (!local.db_use_existing && var.db_require_ssl && !var.db_publicly_accessible)
      error_message = "In-task PostGIS initialization requires module-managed private RDS with TLS. Existing databases must be initialized by their owner."
    }
  }
}

resource "aws_secretsmanager_secret" "postgis_password" {
  #checkov:skip=CKV2_AWS_57: Rotate together with the RDS password and connection secret; automatic independent rotation would break startup.
  count       = var.postgis_bootstrap_image == null ? 0 : 1
  name_prefix = "${local.name}-postgis-"
  kms_key_id  = local.kms_key_arn
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "postgis_password" {
  count         = var.postgis_bootstrap_image == null ? 0 : 1
  secret_id     = aws_secretsmanager_secret.postgis_password[0].id
  secret_string = local.db_password
}
