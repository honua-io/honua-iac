# ---------------------------------------------------------------------------
# Amazon RDS Proxy in front of the module-managed PostgreSQL (opt-in).
#
# Every warm API Lambda environment, every warm control-plane event Lambda and
# every running GP Batch job opens its own Npgsql pools, and a frozen Lambda
# environment keeps its connections until it is retired. On a db.t3.micro
# (~82 usable connections) the pool caps and reserved concurrency do not close
# that budget once the API scales out (honua-release e2e-cloud-aws run
# 38133126673: "53300: remaining connection slots are reserved" reached the API
# host and crashed cold starts in the PostGIS preflight). The proxy owns the
# database connections instead: it opens at most max_connections_percent of the
# instance's max_connections, makes excess demand wait (connection_borrow_timeout)
# rather than fail with 53300, and closes client connections idle longer than
# idle_client_timeout, which reclaims what frozen environments hold.
#
# Routing. When enable_rds_proxy is on, the Lambda functions (API and
# control-plane events) and the GP Batch job definitions read a second,
# module-built connection-string secret (proxy_connection_string) whose Host is
# the proxy endpoint (local.runtime_connection_secret). The original
# connection_string secret keeps the DIRECT instance endpoint: it is what the
# out-of-band migration (migrate_db_connection_secret_arn on the example root),
# release-harness migration and fixture seeding, and the db_connection_string
# output use, because those run from outside the VPC (a runner admitted through
# db_publicly_accessible + db_additional_ingress_cidrs) where the proxy, which
# is VPC-only, is unreachable. The enable_postgis local-exec (CREATE EXTENSION
# as the master user) also stays on the direct endpoint: the runner's CIDR is
# admitted on the RDS security group only, and a one-off DDL session gains
# nothing from a proxy.
#
# Pinning. RDS Proxy for PostgreSQL pins a client connection to one database
# connection, until the client disconnects, after SET / set_config, PREPARE /
# DISCARD (including Npgsql's DISCARD ALL reset on pool return), session
# advisory locks, LISTEN, temporary tables, cursors or a statement over 16 KB.
# The proxy connection string therefore carries:
#   - No Reset On Close=true: no DISCARD ALL on pool return. honua-server's
#     main NpgsqlDataSource already sets this itself (PostgresDataSourceFactory);
#     the keyword covers pools opened straight from the string (the startup
#     PostGIS preflight, snapshot-refresh connections).
#   - Max Auto Prepare=0: no automatic server-side prepared statements (the
#     Npgsql default, pinned explicitly so a driver default cannot change it).
#   - Database__SessionSettings__Mode=role-defaults on every server process
#     (local.db_session_settings_environment, merged into
#     local.db_pool_environment, so the API Lambda, the control-plane event
#     Lambdas and the GP Batch jobs get it; the egress-isolation provisioning
#     job definition adds it explicitly). Without it the server's main data
#     source runs SET lock_timeout / statement_timeout /
#     idle_in_transaction_session_timeout in a physical-connection initializer,
#     which pins every pooled client connection 1:1 (honua-release
#     e2e-cloud-aws run 38163689854: 53300 through the proxy). With it the
#     server issues no SET (honua-server #5870 / #5874) and expects the values
#     as defaults on the database role (it logs event 5870 with the ALTER ROLE
#     statements when they are missing); null_resource.db_role_session_defaults
#     (main.tf) sets them on the direct endpoint before the proxy target exists.
#   - Database:QueryCache:EnableAutomaticCaching=false on every server
#     process (local.db_proxy_query_cache_environment). With it on (the server
#     default) each API instance's HighFrequencyQueryPreparationService
#     PREPAREs its hot queries on one pooled connection about 5 s after start,
#     and PreparedStatementCache PREPAREs repeated request SQL. PREPARE pins,
#     and the pinned connection stays in the Npgsql pool of a frozen
#     environment until the proxy reaps it (idle_client_timeout). honua-release
#     e2e-cloud-aws run 40865466550 (aws-serverless/redis-on, db.t3.micro): the
#     proxy's pinned count equalled its borrowed count all run (4 of 4 before
#     load); the S9 demo burst took the API to 39 concurrent environments, every
#     one of the proxy's 25 allowed database connections was pinned, borrow
#     latency reached 29 s and API invocations and inits hit the 30 s timeout
#     (gateway 503 with integrationStatus 200), and the pins held from 14:19
#     to 14:26 UTC, failing /healthz/ready, an API-key revoke and a datasource
#     test minutes after the burst. Unprepared parameterized commands (the
#     extended protocol's unnamed statements) multiplex.
#     The Lambda functions get it through the settings document
#     (local.db_proxy_settings_document, runtime-settings.tf), which has no
#     4 KB environment cap; the GP Batch jobs get the environment variable.
# What can still pin: session advisory locks (migrations, schedulers) and
# tenant set_config calls. Those pins last only until the client disconnects;
# the proxy's ceiling, borrow queue and idle-client reaping still bound the
# database.
# ---------------------------------------------------------------------------

locals {
  # The proxy fronts only the module-managed instance. existing_db_connection_string
  # is sensitive, but whether an existing database is used reveals nothing.
  rds_proxy_enabled = var.enable_rds_proxy && !nonsensitive(local.db_use_existing)
  rds_proxy_name    = "${local.name}-pg-proxy"

  db_proxy_connection_options = ";No Reset On Close=true;Max Auto Prepare=0"

  # Server processes behind the proxy take their session timeouts from the
  # database role's defaults instead of a per-connection SET (see Pinning).
  # Merged into local.db_pool_environment (main.tf).
  db_session_settings_environment = local.rds_proxy_enabled ? {
    Database__SessionSettings__Mode = "role-defaults"
  } : {}

  # No server-side prepared statements behind the proxy (see Pinning). The
  # Lambda functions read it from the settings document; the GP Batch jobs,
  # which have no environment cap, from the environment (main.tf).
  db_proxy_settings_document = local.rds_proxy_enabled ? {
    Database = { QueryCache = { EnableAutomaticCaching = false } }
  } : {}
  db_proxy_query_cache_environment = local.rds_proxy_enabled ? {
    Database__QueryCache__EnableAutomaticCaching = "false"
  } : {}
  db_proxy_connection_string = local.rds_proxy_enabled ? join("", [
    "Host=${aws_db_proxy.this[0].endpoint};Port=5432;Database=${var.db_name};Username=${var.db_username};Password=${local.db_password}",
    local.db_ssl, local.db_pool_options, local.db_proxy_connection_options, local.db_conn_options,
  ]) : ""

  # The connection-string secret every server process reads at runtime.
  runtime_connection_secret = local.rds_proxy_enabled ? aws_secretsmanager_secret.proxy_connection_string[0] : aws_secretsmanager_secret.connection_string

  # Security groups whose tasks reach PostgreSQL through the proxy.
  rds_proxy_client_security_groups = local.rds_proxy_enabled ? merge(
    { lambda = aws_security_group.lambda.id },
    local.gp_batch_enabled ? { gp_batch = one(aws_security_group.batch[*].id) } : {},
    local.egress_isolation_enabled ? {
      gp_batch_execution = one(aws_security_group.batch_execution[*].id)
    } : {},
  ) : {}
}

resource "terraform_data" "rds_proxy_inputs" {
  count = var.enable_rds_proxy ? 1 : 0

  lifecycle {
    precondition {
      condition     = !nonsensitive(local.db_use_existing)
      error_message = "enable_rds_proxy fronts the module-managed RDS instance only; with existing_db_endpoint / existing_db_connection_string, put a proxy in front of your own database and pass its endpoint instead."
    }
    precondition {
      condition     = var.rds_proxy_max_idle_connections_percent <= var.rds_proxy_max_connections_percent
      error_message = "rds_proxy_max_idle_connections_percent must not exceed rds_proxy_max_connections_percent."
    }
  }
}

# --- Credentials -----------------------------------------------------------
# RDS Proxy authenticates to the database with a Secrets Manager secret in the
# {"username","password"} form; the module only stores a connection string, so
# this secret carries the same master credentials. The password is already in
# state (random_password.db, the connection_string secret version, the RDS
# instance), and AWS provider >= 5.0 / Terraform >= 1.5 offer no write-only
# secret value, so this adds one more state copy and no new exposure class.
#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module; the proxy reads the current master credentials.
resource "aws_secretsmanager_secret" "rds_proxy_auth" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module; the proxy reads the current master credentials.
  count       = local.rds_proxy_enabled ? 1 : 0
  name        = "${local.name}/rds-proxy-auth"
  description = "PostgreSQL credentials RDS Proxy uses to connect to the Honua database."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "rds_proxy_auth" {
  count     = local.rds_proxy_enabled ? 1 : 0
  secret_id = aws_secretsmanager_secret.rds_proxy_auth[0].id
  secret_string = jsonencode({
    username = var.db_username
    password = local.db_password
  })
}

# The connection string the server processes use when the proxy is on. The
# name (".../db-proxy-connection") is not ambiguous with an ARN suffix, so the
# Lambda functions reference it by name (Lambda environment budget).
#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
resource "aws_secretsmanager_secret" "proxy_connection_string" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
  count       = local.rds_proxy_enabled ? 1 : 0
  name        = "${local.name}/db-proxy-connection"
  description = "Database connection string for Honua through RDS Proxy."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "proxy_connection_string" {
  count         = local.rds_proxy_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.proxy_connection_string[0].id
  secret_string = local.db_proxy_connection_string
}

# --- IAM -------------------------------------------------------------------
# The trust policy carries no aws:SourceAccount / aws:SourceArn condition: RDS
# Proxy does not supply global condition context keys when it assumes the role,
# so such a condition would deny it and the proxy could not read its
# credentials. The proxy reads only its own credentials secret. The secret is encrypted with
# the AWS-managed Secrets Manager key, whose key policy already admits callers in
# this account through Secrets Manager, so no kms grant is needed.
resource "aws_iam_role" "rds_proxy" {
  count                = local.rds_proxy_enabled ? 1 : 0
  permissions_boundary = var.permissions_boundary_arn
  name_prefix          = "${local.name}-rds-proxy-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "rds_proxy" {
  count = local.rds_proxy_enabled ? 1 : 0
  name  = "${local.name}-rds-proxy-secret"
  role  = aws_iam_role.rds_proxy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.rds_proxy_auth[0].arn]
    }]
  })
}

# --- Network ---------------------------------------------------------------
# No inline rules, matching aws_security_group.rds: every rule is standalone.
#checkov:skip=CKV2_AWS_5: Security group is attached to the RDS Proxy.
resource "aws_security_group" "rds_proxy" {
  #checkov:skip=CKV2_AWS_5: Security group is attached to the RDS Proxy.
  count       = local.rds_proxy_enabled ? 1 : 0
  name_prefix = "${local.name}-rds-proxy-"
  description = "RDS Proxy security group"
  vpc_id      = local.vpc_id
  tags        = local.tags
}

resource "aws_security_group_rule" "rds_proxy_from_clients" {
  for_each                 = local.rds_proxy_client_security_groups
  type                     = "ingress"
  description              = "PostgreSQL from ${each.key}"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_proxy[0].id
  source_security_group_id = each.value
}

resource "aws_security_group_rule" "rds_proxy_to_rds" {
  count                    = local.rds_proxy_enabled ? 1 : 0
  type                     = "egress"
  description              = "PostgreSQL to the Honua RDS instance"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_proxy[0].id
  source_security_group_id = aws_security_group.rds[0].id
}

resource "aws_security_group_rule" "rds_from_rds_proxy" {
  count                    = local.rds_proxy_enabled ? 1 : 0
  type                     = "ingress"
  description              = "PostgreSQL from RDS Proxy"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds[0].id
  source_security_group_id = aws_security_group.rds_proxy[0].id
}

# --- Proxy -----------------------------------------------------------------
resource "aws_db_proxy" "this" {
  count                  = local.rds_proxy_enabled ? 1 : 0
  name                   = local.rds_proxy_name
  engine_family          = "POSTGRESQL"
  require_tls            = true
  idle_client_timeout    = var.rds_proxy_idle_client_timeout_seconds
  debug_logging          = false
  role_arn               = aws_iam_role.rds_proxy[0].arn
  vpc_subnet_ids         = local.private_subnets
  vpc_security_group_ids = [aws_security_group.rds_proxy[0].id]

  auth {
    description = "Honua database master credentials"
    auth_scheme = "SECRETS"
    # checkov:skip=CKV_SECRET_6: An auth-scheme enum value, not a credential.
    client_password_auth_type = "POSTGRES_SCRAM_SHA_256"
    iam_auth                  = "DISABLED"
    secret_arn                = aws_secretsmanager_secret.rds_proxy_auth[0].arn
  }

  tags = local.tags

  depends_on = [
    aws_secretsmanager_secret_version.rds_proxy_auth,
    aws_iam_role_policy.rds_proxy,
  ]
}

resource "aws_db_proxy_default_target_group" "this" {
  count         = local.rds_proxy_enabled ? 1 : 0
  db_proxy_name = aws_db_proxy.this[0].name

  connection_pool_config {
    # The remainder of max_connections stays free for direct sessions:
    # migrations, the PostGIS bootstrap, fixture seeding and operators.
    max_connections_percent      = var.rds_proxy_max_connections_percent
    max_idle_connections_percent = var.rds_proxy_max_idle_connections_percent
    connection_borrow_timeout    = var.rds_proxy_connection_borrow_timeout_seconds
  }
}

resource "aws_db_proxy_target" "this" {
  count                  = local.rds_proxy_enabled ? 1 : 0
  db_proxy_name          = aws_db_proxy.this[0].name
  target_group_name      = aws_db_proxy_default_target_group.this[0].name
  db_instance_identifier = module.rds[0].db_instance_identifier

  # No proxied backend opens before the role carries the session defaults the
  # server (role-defaults mode) relies on.
  depends_on = [null_resource.db_role_session_defaults]
}
