###############################################################################
# Optional RDS Proxy in front of the module-managed PostgreSQL instance.
#
# Why: each Lambda execution environment opens its own Npgsql connection pool,
# so a request burst that scales the function out multiplies database
# connections until Postgres runs out of slots (SQLSTATE 53300 "remaining
# connection slots are reserved…"). The proxy terminates the per-environment
# connections and pools/multiplexes them onto the instance, so bursts queue at
# the proxy instead of erroring at the database.
#
# Enabled with var.db_proxy_enabled; ignored when the stack points at an
# existing external database (existing_db_*). When enabled, the application
# connection string (Secrets Manager: <name>/connection-string) is built
# against the proxy endpoint — local.db_endpoint keeps pointing at the
# instance for enable_postgis / out-of-band administration.
#
# Networking note for no-NAT VPCs: RDS Proxy retrieves its auth secret from
# Secrets Manager over the VPC, so private subnets without internet egress
# need a Secrets Manager interface endpoint reachable from the proxy ENIs
# (the aws-demo example already provisions one with VPC-CIDR ingress).
###############################################################################

locals {
  db_proxy_enabled = var.db_proxy_enabled && !local.db_use_existing
}

# RDS Proxy authenticates to Postgres with credentials read from a Secrets
# Manager secret in the {"username","password"} shape the service requires
# (the app-facing <name>/connection-string secret is a full Npgsql string,
# which the proxy cannot consume).
resource "aws_secretsmanager_secret" "db_proxy_auth" {
  #checkov:skip=CKV_AWS_304: Secret rotation is handled outside this module (same posture as the connection-string secret).
  #checkov:skip=CKV2_AWS_57: Secret rotation is handled outside this module.
  count = local.db_proxy_enabled ? 1 : 0

  name_prefix = "${local.name}/db-proxy-auth-"
  description = "RDS Proxy authentication credentials for ${local.name}-postgres"

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "db_proxy_auth" {
  count = local.db_proxy_enabled ? 1 : 0

  secret_id = aws_secretsmanager_secret.db_proxy_auth[0].id
  secret_string = jsonencode({
    username = var.db_username
    password = local.db_password
  })
}

data "aws_iam_policy_document" "db_proxy_assume" {
  count = local.db_proxy_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "db_proxy_secrets" {
  count = local.db_proxy_enabled ? 1 : 0

  statement {
    sid       = "GetProxyAuthSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db_proxy_auth[0].arn]
  }

  statement {
    sid       = "DecryptViaSecretsManager"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "db_proxy" {
  count = local.db_proxy_enabled ? 1 : 0

  name_prefix        = "${local.name}-db-proxy-"
  assume_role_policy = data.aws_iam_policy_document.db_proxy_assume[0].json

  tags = local.tags
}

resource "aws_iam_role_policy" "db_proxy_secrets" {
  count = local.db_proxy_enabled ? 1 : 0

  name_prefix = "${local.name}-db-proxy-secrets-"
  role        = aws_iam_role.db_proxy[0].id
  policy      = data.aws_iam_policy_document.db_proxy_secrets[0].json
}

resource "aws_security_group" "db_proxy" {
  #checkov:skip=CKV2_AWS_5: Attached to the RDS Proxy below.
  count = local.db_proxy_enabled ? 1 : 0

  name_prefix = "${local.name}-db-proxy-"
  description = "RDS Proxy security group"
  vpc_id      = local.vpc_id

  ingress {
    description     = "PostgreSQL from Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  # Egress to the database subnets only (the rds SG admits the proxy via its
  # own ingress rule; expressing this as an SG reference here would cycle).
  egress {
    description = "PostgreSQL to the database subnets"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = local.tags
}

resource "aws_db_proxy" "db" {
  count = local.db_proxy_enabled ? 1 : 0

  name                   = "${local.name}-pg-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.db_proxy[0].arn
  vpc_subnet_ids         = local.db_subnet_ids
  vpc_security_group_ids = [aws_security_group.db_proxy[0].id]
  require_tls            = var.db_require_ssl
  # Lambda environments idle out well before this; keep the default so the
  # proxy, not the function, owns client-connection lifecycle.
  idle_client_timeout = 1800
  debug_logging       = false

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.db_proxy_auth[0].arn
  }

  tags = local.tags
}

resource "aws_db_proxy_default_target_group" "db" {
  count = local.db_proxy_enabled ? 1 : 0

  db_proxy_name = aws_db_proxy.db[0].name

  connection_pool_config {
    # Leave headroom below Postgres max_connections for enable_postgis,
    # bootstrap jobs, and superuser/rds_reserved slots.
    max_connections_percent      = 90
    max_idle_connections_percent = 50
    connection_borrow_timeout    = 120
  }
}

resource "aws_db_proxy_target" "db" {
  count = local.db_proxy_enabled ? 1 : 0

  db_proxy_name          = aws_db_proxy.db[0].name
  target_group_name      = aws_db_proxy_default_target_group.db[0].name
  db_instance_identifier = module.rds[0].db_instance_identifier
}
