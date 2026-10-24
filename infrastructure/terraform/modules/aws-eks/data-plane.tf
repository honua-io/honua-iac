# Data plane for the Honua workload the Helm chart installs onto this cluster:
# RDS PostgreSQL (+ PostGIS), optional ElastiCache Redis, and the runtime
# secrets the server reads. Semantics mirror modules/aws-ecs so the release
# harness passes the same inputs by name; the difference is delivery. Nothing
# here creates Kubernetes objects: the chart (or the operator) wires the
# aws:secretsmanager: references from the honua_server_environment output, and
# the server resolves them with its workload role (workload-identity.tf).

locals {
  db_use_existing = var.existing_db_endpoint != "" && nonsensitive(var.existing_db_connection_string != "")
  # Pods reach the data plane from the node ENIs (the VPC CNI gives pods node
  # ENI addresses), so both the node and the cluster primary security groups
  # are admitted. GP Job pods run on the same nodes.
  workload_security_group_ids = [module.eks.node_security_group_id, module.eks.cluster_primary_security_group_id]

  db_password          = var.db_password != null ? var.db_password : (local.db_use_existing ? "" : random_password.db[0].result)
  db_ssl               = var.db_require_ssl ? ";SSL Mode=Require;Trust Server Certificate=false" : ""
  db_endpoint          = local.db_use_existing ? var.existing_db_endpoint : module.rds[0].db_instance_address
  db_connection_string = local.db_use_existing ? var.existing_db_connection_string : "Host=${local.db_endpoint};Port=5432;Database=${var.db_name};Username=${var.db_username};Password=${local.db_password}${local.db_ssl}"
  db_subnet_ids        = var.db_publicly_accessible ? module.vpc.public_subnets : module.vpc.private_subnets

  admin_password = var.admin_password != null ? var.admin_password : random_password.admin[0].result
  master_key     = var.connection_encryption_master_key != null ? var.connection_encryption_master_key : random_password.master_key[0].result

  redis_auth_token = var.redis_auth_token != "" ? var.redis_auth_token : (var.redis_enabled ? random_password.redis_auth[0].result : "")
  redis_connection = var.redis_enabled ? "${aws_elasticache_replication_group.redis[0].primary_endpoint_address}:${var.redis_port},password=${local.redis_auth_token},ssl=true${local.redis_client_options}" : ""

  # Empty string means the AWS-managed aws/secretsmanager key.
  secrets_kms_key_id = var.secrets_kms_key_arn != "" ? var.secrets_kms_key_arn : null
}

# Client timeouts on the module-built Redis connection string (README: Redis
# connections). A caller-supplied redis_connection_string is used unchanged.
locals {
  redis_client_options = ",connectTimeout=${var.redis_connect_timeout_ms},syncTimeout=${var.redis_sync_timeout_ms},keepAlive=${var.redis_keep_alive_seconds}"
}

resource "random_password" "db" {
  count   = local.db_use_existing || var.db_password != null ? 0 : 1
  length  = 32
  special = false
}

resource "random_password" "admin" {
  count            = var.admin_password == null ? 1 : 0
  length           = 32
  special          = true
  override_special = "!#$%*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "random_password" "master_key" {
  count   = var.connection_encryption_master_key == null ? 1 : 0
  length  = 48
  special = false
}

resource "random_password" "redis_auth" {
  count            = var.redis_enabled && var.redis_auth_token == "" ? 1 : 0
  length           = 32
  special          = true
  override_special = "!&#$^<>-"
}

check "redis_requires_operation_key_ring" {
  assert {
    condition     = !var.redis_enabled || var.operation_key_ring_certificate_secret_arn != ""
    error_message = "redis_enabled requires operation_key_ring_certificate_secret_arn: with Redis connected the Production server composes the durable operation secret channel and refuses to start without the key-ring certificate. Supply an operator-owned Secrets Manager PKCS#12 bundle ARN."
  }
}

check "audit_chain_key_configured" {
  assert {
    condition     = var.audit_chain_key_secret_arn != ""
    error_message = "audit_chain_key_secret_arn is empty: audit rows are still written, but scheduled hash-chain verification cannot succeed and the server's audit-chain-integrity health check reports Unhealthy. Supply an operator-owned Secrets Manager secret holding a base64 key of at least 32 bytes."
  }
}

# --- PostgreSQL ------------------------------------------------------------------

resource "aws_security_group" "rds" {
  count = local.db_use_existing ? 0 : 1
  #checkov:skip=CKV2_AWS_5: Security group is attached via the RDS module.
  name_prefix = "${local.name}-rds-"
  description = "Honua RDS PostgreSQL"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from EKS workloads"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = local.workload_security_group_ids
  }

  dynamic "ingress" {
    for_each = toset(var.db_additional_ingress_cidrs)
    content {
      description = "PostgreSQL additional CIDR ingress"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "Outbound HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = (var.existing_db_endpoint == "") == (var.existing_db_connection_string == "")
      error_message = "existing_db_endpoint and existing_db_connection_string must both be set or both be empty."
    }
  }
}

#checkov:skip=CKV_TF_1: Registry modules are version-pinned.
#checkov:skip=CKV_AWS_133: Backup retention is configured in this module call.
#checkov:skip=CKV_AWS_304: Secret rotation is handled outside this module.
module "rds" {
  count = local.db_use_existing ? 0 : 1
  #checkov:skip=CKV_TF_1: Registry modules are version-pinned.
  #checkov:skip=CKV_AWS_133: Backup retention is configured in this module call.
  #checkov:skip=CKV_AWS_304: Secret rotation is handled outside this module.
  source  = "terraform-aws-modules/rds/aws"
  version = "6.13.1"

  identifier = "${local.name}-postgres"

  engine               = "postgres"
  engine_version       = var.db_engine_version
  family               = "postgres${split(".", var.db_engine_version)[0]}"
  major_engine_version = split(".", var.db_engine_version)[0]
  instance_class       = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true

  # Server-side TLS, matching modules/aws-ecs.
  create_db_parameter_group = true
  parameters = [
    {
      name         = "rds.force_ssl"
      value        = "1"
      apply_method = "immediate"
    }
  ]

  db_name                     = var.db_name
  username                    = var.db_username
  password                    = local.db_password
  manage_master_user_password = false
  port                        = 5432

  vpc_security_group_ids = [aws_security_group.rds[0].id]
  subnet_ids             = local.db_subnet_ids
  create_db_subnet_group = true

  publicly_accessible = var.db_publicly_accessible
  multi_az            = var.db_multi_az

  backup_retention_period = var.environment == "prod" ? 7 : 3
  maintenance_window      = "Sun:04:00-Sun:05:00"

  deletion_protection              = var.rds_deletion_protection
  skip_final_snapshot              = var.environment != "prod"
  final_snapshot_identifier_prefix = "${local.name}-postgres-final"

  tags = local.tags
}

# PostGIS is not on by default on RDS. Same local-exec bootstrap as aws-ecs: the
# Terraform runner must reach the instance (db_publicly_accessible plus its /32
# in db_additional_ingress_cidrs). A private production database enables the
# extensions from inside the VPC instead.
resource "null_resource" "enable_postgis" {
  count = var.enable_postgis && !local.db_use_existing ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.db_publicly_accessible
      error_message = "enable_postgis uses a local-exec psql bootstrap. Set db_publicly_accessible=true (with the runner CIDR in db_additional_ingress_cidrs); a private RDS needs an in-VPC bootstrap before enabling PostGIS."
    }
  }

  triggers = {
    db_endpoint = local.db_endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "Waiting for PostgreSQL readiness on ${local.db_endpoint}"
      for attempt in $(seq 1 ${var.postgis_readiness_max_attempts}); do
        if PGCONNECT_TIMEOUT=5 psql \
          --host=${local.db_endpoint} \
          --username=${var.db_username} \
          --dbname=${var.db_name} \
          --command="SELECT 1;" >/dev/null 2>&1; then
          echo "PostgreSQL readiness check succeeded after $attempt attempt(s)"
          break
        fi
        if [ "$attempt" -eq ${var.postgis_readiness_max_attempts} ]; then
          echo "PostgreSQL readiness check failed after ${var.postgis_readiness_max_attempts} attempts" >&2
          PGCONNECT_TIMEOUT=5 psql \
            --host=${local.db_endpoint} \
            --username=${var.db_username} \
            --dbname=${var.db_name} \
            --command="SELECT 1;" >&2 || true
          exit 1
        fi
        sleep ${var.postgis_readiness_sleep_seconds}
      done

      echo "Enabling PostGIS + PostGIS Raster on ${local.db_endpoint}"
      PGCONNECT_TIMEOUT=5 psql \
        --host=${local.db_endpoint} \
        --username=${var.db_username} \
        --dbname=${var.db_name} \
        --set=ON_ERROR_STOP=1 \
        --command="CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS postgis_raster;"
    EOT
    environment = {
      PGPASSWORD = local.db_password
      PGSSLMODE  = "require"
    }
  }

  depends_on = [module.rds]
}

# --- Redis -----------------------------------------------------------------------

resource "aws_security_group" "redis" {
  count       = var.redis_enabled ? 1 : 0
  name_prefix = "${local.name}-redis-"
  description = "Honua ElastiCache Redis"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Redis from EKS workloads"
    from_port       = var.redis_port
    to_port         = var.redis_port
    protocol        = "tcp"
    security_groups = local.workload_security_group_ids
  }

  egress {
    description = "Redis outbound within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_subnet_group" "redis" {
  count       = var.redis_enabled ? 1 : 0
  name        = "${local.name}-redis"
  subnet_ids  = module.vpc.private_subnets
  description = "Honua Redis subnet group"
  tags        = local.tags
}

#checkov:skip=CKV2_AWS_50: Single-node Redis is allowed for smaller environments; Multi-AZ activates when cluster count is increased.
#checkov:skip=CKV_AWS_191: At-rest encryption uses the ElastiCache-managed key so ephemeral clusters strand no CMK.
resource "aws_elasticache_replication_group" "redis" {
  #checkov:skip=CKV2_AWS_50: Single-node Redis is allowed for smaller environments; Multi-AZ activates when cluster count is increased.
  #checkov:skip=CKV_AWS_191: At-rest encryption uses the ElastiCache-managed key so ephemeral clusters strand no CMK.
  count                      = var.redis_enabled ? 1 : 0
  replication_group_id       = "${local.name}-redis"
  description                = "Honua Redis"
  node_type                  = var.redis_node_type
  engine                     = "redis"
  engine_version             = var.redis_engine_version
  port                       = var.redis_port
  parameter_group_name       = var.redis_parameter_group_name
  automatic_failover_enabled = var.redis_num_cache_clusters > 1
  multi_az_enabled           = var.redis_num_cache_clusters > 1
  num_cache_clusters         = var.redis_num_cache_clusters
  subnet_group_name          = aws_elasticache_subnet_group.redis[0].name
  security_group_ids         = [aws_security_group.redis[0].id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = local.redis_auth_token
  apply_immediately          = true
  tags                       = local.tags
}

# --- Secrets ---------------------------------------------------------------------

#checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
#checkov:skip=CKV_AWS_149: The AWS-managed key is the default so ephemeral clusters strand no CMK; secrets_kms_key_arn selects a CMK.
resource "aws_secretsmanager_secret" "db_connection" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
  #checkov:skip=CKV_AWS_149: The AWS-managed key is the default so ephemeral clusters strand no CMK; secrets_kms_key_arn selects a CMK.
  name_prefix = "${local.name}-db-"
  description = "Honua database connection string (ConnectionStrings:DefaultConnection)"
  kms_key_id  = local.secrets_kms_key_id
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "db_connection" {
  secret_id     = aws_secretsmanager_secret.db_connection.id
  secret_string = local.db_connection_string
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
#checkov:skip=CKV_AWS_149: The AWS-managed key is the default so ephemeral clusters strand no CMK; secrets_kms_key_arn selects a CMK.
resource "aws_secretsmanager_secret" "admin_password" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
  #checkov:skip=CKV_AWS_149: The AWS-managed key is the default so ephemeral clusters strand no CMK; secrets_kms_key_arn selects a CMK.
  name_prefix = "${local.name}-admin-"
  description = "Honua bootstrap admin password (HONUA_ADMIN_PASSWORD)"
  kms_key_id  = local.secrets_kms_key_id
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "admin_password" {
  secret_id     = aws_secretsmanager_secret.admin_password.id
  secret_string = local.admin_password
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is handled through the Honua key-rotation procedure.
#checkov:skip=CKV_AWS_149: The AWS-managed key is the default so ephemeral clusters strand no CMK; secrets_kms_key_arn selects a CMK.
resource "aws_secretsmanager_secret" "master_key" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is handled through the Honua key-rotation procedure.
  #checkov:skip=CKV_AWS_149: The AWS-managed key is the default so ephemeral clusters strand no CMK; secrets_kms_key_arn selects a CMK.
  name_prefix = "${local.name}-connection-encryption-"
  description = "Honua connection-encryption master key (Security:ConnectionEncryption:MasterKey)"
  kms_key_id  = local.secrets_kms_key_id
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "master_key" {
  secret_id     = aws_secretsmanager_secret.master_key.id
  secret_string = local.master_key
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
#checkov:skip=CKV_AWS_149: The AWS-managed key is the default so ephemeral clusters strand no CMK; secrets_kms_key_arn selects a CMK.
resource "aws_secretsmanager_secret" "redis_connection" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
  #checkov:skip=CKV_AWS_149: The AWS-managed key is the default so ephemeral clusters strand no CMK; secrets_kms_key_arn selects a CMK.
  count       = var.redis_enabled ? 1 : 0
  name_prefix = "${local.name}-redis-"
  description = "Honua Redis connection string (ConnectionStrings:redis)"
  kms_key_id  = local.secrets_kms_key_id
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "redis_connection" {
  count         = var.redis_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.redis_connection[0].id
  secret_string = local.redis_connection
}
