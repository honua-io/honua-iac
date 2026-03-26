data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  name = "${var.name_prefix}-${var.environment}"
  tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.tags)
  use_existing_vpc                 = var.existing_vpc_id != ""
  vpc_id                           = local.use_existing_vpc ? var.existing_vpc_id : module.vpc[0].vpc_id
  vpc_cidr_block                   = local.use_existing_vpc ? var.existing_vpc_cidr : module.vpc[0].vpc_cidr_block
  public_subnets                   = local.use_existing_vpc ? var.existing_public_subnet_ids : module.vpc[0].public_subnets
  private_subnets                  = local.use_existing_vpc ? var.existing_private_subnet_ids : module.vpc[0].private_subnets
  db_use_existing                  = var.existing_db_endpoint != "" && var.existing_db_connection_string != ""
  redis_enabled                    = var.redis_enabled || var.redis_connection_string != ""
  redis_create                     = var.redis_enabled && var.redis_connection_string == ""
  redis_auth_token                 = var.redis_auth_token != "" ? var.redis_auth_token : (local.redis_create ? random_password.redis_auth[0].result : "")
  redis_connection                 = var.redis_connection_string != "" ? var.redis_connection_string : (local.redis_create ? "${aws_elasticache_replication_group.redis[0].primary_endpoint_address}:${var.redis_port},password=${local.redis_auth_token},ssl=true" : "")
  connection_encryption_master_key = var.connection_encryption_master_key != null ? var.connection_encryption_master_key : random_password.connection_encryption_master_key[0].result
  redis_egress_cidrs               = local.redis_create ? [local.vpc_cidr_block] : var.redis_connection_cidrs
  app_storage_prefix               = trimprefix(trimsuffix(trimspace(var.app_storage_prefix), "/"), "/")
  app_storage_bucket_name = var.app_storage_enabled ? (
    trimspace(var.app_storage_bucket_name) != ""
    ? lower(trimspace(var.app_storage_bucket_name))
    : substr(replace(lower("${var.name_prefix}-${var.environment}-app-${random_id.app_storage_suffix[0].hex}"), "_", "-"), 0, 63)
  ) : null
}

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
    error_message = "Provide existing_db_admin_password or db_password when enabling PostGIS on an existing database."
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
    error_message = "Set either redis_enabled = true to provision Redis or redis_connection_string to reuse an existing Redis instance, not both."
  }
}

check "db_storage_autoscaling_bounds" {
  assert {
    condition     = var.db_max_allocated_storage >= var.db_allocated_storage
    error_message = "db_max_allocated_storage must be greater than or equal to db_allocated_storage."
  }
}

resource "random_password" "db" {
  count            = var.db_password == null && !local.db_use_existing ? 1 : 0
  length           = 32
  special          = true
  override_special = "#%*()-_=+[]{}:?."

  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

resource "random_password" "connection_encryption_master_key" {
  count            = var.connection_encryption_master_key == null ? 1 : 0
  length           = 32
  special          = true
  override_special = "#%*()-_=+[]{}:?."

  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

resource "random_password" "redis_auth" {
  count            = local.redis_create && var.redis_auth_token == "" ? 1 : 0
  length           = 32
  special          = true
  override_special = "!&#$^<>-"

  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

resource "random_id" "app_storage_suffix" {
  count       = var.app_storage_enabled && trimspace(var.app_storage_bucket_name) == "" ? 1 : 0
  byte_length = 4
}

locals {
  db_password          = var.db_password != null ? var.db_password : (local.db_use_existing ? var.existing_db_admin_password : random_password.db[0].result)
  db_ssl               = var.db_require_ssl ? ";SSL Mode=Require;Trust Server Certificate=false" : ""
  db_endpoint          = local.db_use_existing ? var.existing_db_endpoint : module.rds[0].db_instance_address
  db_connection_string = local.db_use_existing ? var.existing_db_connection_string : "Host=${local.db_endpoint};Port=5432;Database=${var.db_name};Username=${var.db_username};Password=${local.db_password}${local.db_ssl}"
  lambda_function_name = "${local.name}-honua"
  lambda_target_id     = "${local.lambda_function_name}-${var.lambda_alias_name}"
  app_storage_environment = var.app_storage_enabled ? {
    FileStorage__Provider                          = "AwsS3"
    FileStorage__AwsS3__BucketName                 = local.app_storage_bucket_name
    FileStorage__AwsS3__Region                     = data.aws_region.current.id
    FileStorage__AwsS3__KeyPrefix                  = local.app_storage_prefix
    FileStorage__AwsS3__EnableServerSideEncryption = "true"
  } : {}
  redis_environment = local.redis_connection != "" ? {
    ConnectionStrings__redis = local.redis_connection
  } : {}
  lambda_environment = merge({
    HONUA_SKIP_MIGRATIONS                                       = var.skip_migrations ? "true" : "false"
    HostValidation__AllowedHosts__0                             = "*.execute-api.${data.aws_region.current.id}.amazonaws.com"
    ConnectionStrings__DefaultConnection                        = local.db_connection_string
    HONUA_ADMIN_PASSWORD                                        = var.admin_password
    Security__ConnectionEncryption__MasterKey                   = local.connection_encryption_master_key
    HONUA_SERVE_ADMIN_UI                                        = var.serve_admin_ui ? "true" : "false"
    HONUA_ADMIN_UI                                              = var.serve_admin_ui ? "true" : "false"
    HONUA_OBSERVABILITY                                         = "true"
    ControlPlane__DeployTargets__0__TargetId                    = local.lambda_target_id
    ControlPlane__DeployTargets__0__TargetKind                  = "AwsLambda"
    ControlPlane__DeployTargets__0__Backend                     = "honua-gitops-aws-lambda"
    ControlPlane__DeployTargets__0__Environment                 = var.environment
    ControlPlane__DeployTargets__0__TargetName                  = local.lambda_function_name
    ControlPlane__DeployTargets__0__ArtifactReference           = var.image
    ControlPlane__DeployTargets__0__RequiresOutOfBandMigrations = "true"
    ControlPlane__DeployTargets__0__ParameterEntries__0__Key    = "aws.lambda.function_name"
    ControlPlane__DeployTargets__0__ParameterEntries__0__Value  = local.lambda_function_name
    ControlPlane__DeployTargets__0__ParameterEntries__1__Key    = "aws.lambda.alias_name"
    ControlPlane__DeployTargets__0__ParameterEntries__1__Value  = var.lambda_alias_name
    ControlPlane__DeployTargets__0__ParameterEntries__2__Key    = "aws.region"
    ControlPlane__DeployTargets__0__ParameterEntries__2__Value  = data.aws_region.current.id
  }, local.app_storage_environment, var.additional_env, local.redis_environment)
}

provider "postgresql" {
  alias           = "honua"
  host            = local.db_endpoint
  port            = 5432
  database        = var.db_name
  username        = var.db_username
  password        = local.db_password
  sslmode         = var.db_require_ssl ? "require" : "disable"
  connect_timeout = 10
}

#checkov:skip=CKV_TF_1: Registry modules are version-pinned.
module "vpc" {
  count = local.use_existing_vpc ? 0 : 1
  #checkov:skip=CKV_TF_1: Registry modules are version-pinned.
  #checkov:skip=CKV2_AWS_12: Default SG is managed via module inputs.
  source = "../vendor/aws-vpc"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, length(var.public_subnet_cidrs))
  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

  enable_nat_gateway             = var.enable_nat_gateway
  single_nat_gateway             = var.single_nat_gateway
  enable_dns_support             = true
  enable_dns_hostnames           = true
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  tags = local.tags
}

locals {
  db_subnet_ids = var.db_publicly_accessible ? local.public_subnets : local.private_subnets
}

#checkov:skip=CKV2_AWS_5: Security group is attached to the Lambda function.
resource "aws_security_group" "lambda" {
  #checkov:skip=CKV2_AWS_5: Security group is attached to the Lambda function.
  name_prefix = "${local.name}-lambda-"
  description = "Lambda security group"
  vpc_id      = local.vpc_id

  egress {
    description = "PostgreSQL access"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  dynamic "egress" {
    for_each = local.db_use_existing ? [1] : []
    content {
      description = "Existing PostgreSQL access"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = var.existing_db_cidrs
    }
  }

  dynamic "egress" {
    for_each = local.redis_enabled ? [1] : []
    content {
      description = "Redis access"
      from_port   = var.redis_port
      to_port     = var.redis_port
      protocol    = "tcp"
      cidr_blocks = local.redis_egress_cidrs
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
}

#checkov:skip=CKV2_AWS_5: Security group is attached to the RDS instance.
resource "aws_security_group" "rds" {
  count = local.db_use_existing ? 0 : 1
  #checkov:skip=CKV2_AWS_5: Security group is attached to the RDS instance.
  name_prefix = "${local.name}-rds-"
  description = "RDS security group"
  vpc_id      = local.vpc_id

  ingress {
    description     = "PostgreSQL from Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
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

  tags = local.tags
}

#checkov:skip=CKV2_AWS_5: Security group is attached through the replication group below.
resource "aws_security_group" "redis" {
  #checkov:skip=CKV2_AWS_5: Security group is attached through the replication group below.
  count       = local.redis_create ? 1 : 0
  name_prefix = "${local.name}-redis-"
  description = "Redis security group"
  vpc_id      = local.vpc_id

  ingress {
    description     = "Redis from Lambda"
    from_port       = var.redis_port
    to_port         = var.redis_port
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  tags = local.tags
}

resource "aws_elasticache_subnet_group" "redis" {
  count       = local.redis_create ? 1 : 0
  name        = "${local.name}-redis"
  subnet_ids  = local.private_subnets
  description = "Redis subnet group"
  tags        = local.tags
}

#checkov:skip=CKV2_AWS_50: Single-node Redis is allowed for smaller environments; Multi-AZ activates when cluster count is increased.
resource "aws_elasticache_replication_group" "redis" {
  #checkov:skip=CKV2_AWS_50: Single-node Redis is allowed for smaller environments; Multi-AZ activates when cluster count is increased.
  count                      = local.redis_create ? 1 : 0
  replication_group_id       = "${local.name}-redis"
  description                = "Honua Redis"
  node_type                  = var.redis_node_type
  engine                     = "redis"
  engine_version             = var.redis_engine_version
  port                       = var.redis_port
  parameter_group_name       = var.redis_parameter_group_name
  automatic_failover_enabled = var.redis_num_cache_clusters >= 2
  multi_az_enabled           = var.redis_num_cache_clusters >= 2
  num_cache_clusters         = var.redis_num_cache_clusters
  subnet_group_name          = aws_elasticache_subnet_group.redis[0].name
  security_group_ids         = [aws_security_group.redis[0].id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = local.redis_auth_token
  apply_immediately          = true
  tags                       = local.tags

  lifecycle {
    precondition {
      condition     = var.redis_num_cache_clusters >= 1
      error_message = "redis_num_cache_clusters must be >= 1."
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
  version = "~> 6.0"

  identifier = "${local.name}-postgres"

  engine               = "postgres"
  engine_version       = var.db_engine_version
  family               = "postgres${split(".", var.db_engine_version)[0]}"
  major_engine_version = split(".", var.db_engine_version)[0]
  instance_class       = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true

  db_name                     = var.db_name
  username                    = var.db_username
  password                    = local.db_password
  manage_master_user_password = false
  port                        = 5432

  vpc_security_group_ids = local.db_use_existing ? [] : [aws_security_group.rds[0].id]
  subnet_ids             = local.db_subnet_ids
  create_db_subnet_group = true

  publicly_accessible = var.db_publicly_accessible
  multi_az            = var.db_multi_az

  backup_retention_period = var.environment == "prod" ? 7 : 3
  maintenance_window      = var.db_maintenance_window

  tags = local.tags
}

data "aws_db_snapshot" "latest" {
  count                  = local.db_use_existing ? 0 : 1
  db_instance_identifier = module.rds[0].db_instance_identifier
  most_recent            = true

  depends_on = [module.rds]
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name_prefix        = "${local.name}-lambda-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

#checkov:skip=CKV_AWS_356: Lambda VPC ENI actions do not support resource-level restriction.
#checkov:skip=CKV_AWS_111: Lambda VPC ENI actions require wildcard scope and are limited to the documented action set.
data "aws_iam_policy_document" "lambda_runtime" {
  #checkov:skip=CKV_AWS_356: Lambda VPC ENI actions do not support resource-level restriction.
  #checkov:skip=CKV_AWS_111: Lambda VPC ENI actions require wildcard scope and are limited to the documented action set.
  statement {
    sid = "WriteFunctionLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  statement {
    sid = "ManageVpcNetworkInterfaces"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda_runtime" {
  name        = "${local.name}-lambda-runtime"
  description = "Least-privilege Lambda runtime policy for logs and VPC networking"
  policy      = data.aws_iam_policy_document.lambda_runtime.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_runtime" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_runtime.arn
}

resource "aws_iam_policy" "lambda_app_storage" {
  count = var.app_storage_enabled ? 1 : 0

  name = "${local.name}-lambda-app-storage"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.app_storage[0].arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = ["${aws_s3_bucket.app_storage[0].arn}/${local.app_storage_prefix}/*"]
      }
    ]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_app_storage" {
  count = var.app_storage_enabled ? 1 : 0

  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_app_storage[0].arn
}

resource "time_sleep" "lambda_role_propagation" {
  create_duration = "20s"

  depends_on = [
    aws_iam_role.lambda,
    aws_iam_role_policy_attachment.lambda_runtime,
    aws_iam_role_policy_attachment.lambda_app_storage,
  ]
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
resource "aws_secretsmanager_secret" "connection_string" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
  name        = "${local.name}/connection-string"
  description = "Database connection string for Honua."
  tags        = local.tags
}

#checkov:skip=CKV_AWS_18: Access logging is optional for this application bucket and can be layered on centrally by operators.
#checkov:skip=CKV2_AWS_62: Event notifications are deployment-specific and not required for baseline runtime storage.
#checkov:skip=CKV_AWS_145: SSE-S3 avoids widening runtime KMS permissions for the application bucket.
#checkov:skip=CKV_AWS_144: Cross-region replication is optional and environment-specific for application file storage.
#checkov:skip=CKV2_AWS_61: Lifecycle policies depend on tenant retention requirements and are managed per environment.
resource "aws_s3_bucket" "app_storage" {
  #checkov:skip=CKV_AWS_18: Access logging is optional for this application bucket and can be layered on centrally by operators.
  #checkov:skip=CKV2_AWS_62: Event notifications are deployment-specific and not required for baseline runtime storage.
  #checkov:skip=CKV_AWS_145: SSE-S3 avoids widening runtime KMS permissions for the application bucket.
  #checkov:skip=CKV_AWS_144: Cross-region replication is optional and environment-specific for application file storage.
  #checkov:skip=CKV2_AWS_61: Lifecycle policies depend on tenant retention requirements and are managed per environment.
  count = var.app_storage_enabled ? 1 : 0

  bucket        = local.app_storage_bucket_name
  force_destroy = var.app_storage_force_destroy
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "app_storage" {
  count = var.app_storage_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.app_storage[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "app_storage" {
  count = var.app_storage_enabled ? 1 : 0

  bucket = aws_s3_bucket.app_storage[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_storage" {
  count = var.app_storage_enabled ? 1 : 0

  bucket = aws_s3_bucket.app_storage[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_secretsmanager_secret_version" "connection_string" {
  secret_id     = aws_secretsmanager_secret.connection_string.id
  secret_string = local.db_connection_string
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
resource "aws_secretsmanager_secret" "admin_password" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
  name        = "${local.name}/admin-password"
  description = "Admin API password for Honua."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "admin_password" {
  secret_id     = aws_secretsmanager_secret.admin_password.id
  secret_string = var.admin_password
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
resource "aws_secretsmanager_secret" "connection_encryption_master_key" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
  name        = "${local.name}/connection-encryption-master-key"
  description = "Honua connection encryption master key."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "connection_encryption_master_key" {
  secret_id     = aws_secretsmanager_secret.connection_encryption_master_key.id
  secret_string = local.connection_encryption_master_key
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
resource "aws_secretsmanager_secret" "redis_connection" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
  count       = local.redis_enabled ? 1 : 0
  name        = "${local.name}/redis-connection"
  description = "Redis connection string for Honua."
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "redis_connection" {
  count         = local.redis_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.redis_connection[0].id
  secret_string = local.redis_connection
}

#checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
resource "aws_cloudwatch_log_group" "lambda" {
  #checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
  name              = "/aws/lambda/${local.name}-honua"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

#checkov:skip=CKV_AWS_50: X-Ray tracing is optional and can be enabled by the deployment environment.
#checkov:skip=CKV_AWS_116: DLQ wiring is environment-specific and not required for every deployment target.
#checkov:skip=CKV_AWS_173: Secrets are injected through Secrets Manager references rather than plaintext environment values.
#checkov:skip=CKV_AWS_272: Code signing is optional for private image-based deployments.
resource "aws_lambda_function" "this" {
  #checkov:skip=CKV_AWS_50: X-Ray tracing is optional and can be enabled by the deployment environment.
  #checkov:skip=CKV_AWS_116: DLQ wiring is environment-specific and not required for every deployment target.
  #checkov:skip=CKV_AWS_173: Secrets are injected through Secrets Manager references rather than plaintext environment values.
  #checkov:skip=CKV_AWS_272: Code signing is optional for private image-based deployments.
  function_name = local.lambda_function_name
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = var.image
  publish       = true

  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout_seconds

  architectures = var.lambda_architectures

  ephemeral_storage {
    size = var.lambda_ephemeral_storage_mb
  }

  reserved_concurrent_executions = var.lambda_reserved_concurrent_executions

  vpc_config {
    subnet_ids         = local.private_subnets
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = local.lambda_environment
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_secretsmanager_secret_version.connection_string,
    aws_secretsmanager_secret_version.admin_password,
    aws_secretsmanager_secret_version.connection_encryption_master_key,
    aws_secretsmanager_secret_version.redis_connection,
    time_sleep.lambda_role_propagation,
  ]

  tags = local.tags
}

resource "aws_lambda_alias" "live" {
  name             = var.lambda_alias_name
  description      = "Stable Honua deploy alias managed by the control plane."
  function_name    = aws_lambda_function.this.function_name
  function_version = coalesce(var.lambda_alias_version, aws_lambda_function.this.version)
}

#checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
resource "aws_cloudwatch_log_group" "api_gateway" {
  #checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
  name              = "/aws/apigateway/${local.name}-honua"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${local.name}-honua"
  protocol_type = "HTTP"

  dynamic "cors_configuration" {
    for_each = var.cors_allowed_origins != null ? [1] : []
    content {
      allow_origins = var.cors_allowed_origins
      allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
      allow_headers = ["Content-Type", "Authorization", "X-API-Key"]
      max_age       = 300
    }
  }

  tags = local.tags
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.live.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = min(30000, var.lambda_timeout_seconds * 1000)
}

#checkov:skip=CKV_AWS_309: API Gateway intentionally forwards both public and authenticated traffic to Honua for in-app authorization.
resource "aws_apigatewayv2_route" "root" {
  #checkov:skip=CKV_AWS_309: API Gateway intentionally forwards both public and authenticated traffic to Honua for in-app authorization.
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

#checkov:skip=CKV_AWS_309: API Gateway intentionally forwards both public and authenticated traffic to Honua for in-app authorization.
resource "aws_apigatewayv2_route" "proxy" {
  #checkov:skip=CKV_AWS_309: API Gateway intentionally forwards both public and authenticated traffic to Honua for in-app authorization.
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceIp       = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      path           = "$context.path"
      status         = "$context.status"
      responseLength = "$context.responseLength"
    })
  }

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = var.api_throttle_burst_limit
    throttling_rate_limit    = var.api_throttle_rate_limit
  }

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda function error rate is elevated."
  dimensions = {
    FunctionName = aws_lambda_function.this.function_name
  }
  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name}-api-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5xx"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "API Gateway 5xx error rate is elevated."
  dimensions = {
    ApiId = aws_apigatewayv2_api.this.id
  }
  tags = local.tags
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "postgresql_extension" "postgis" {
  count        = var.enable_postgis ? 1 : 0
  provider     = postgresql.honua
  name         = "postgis"
  schema       = "public"
  drop_cascade = true

  depends_on = [
    module.rds,
  ]
}

resource "postgresql_extension" "postgis_raster" {
  count        = var.enable_postgis ? 1 : 0
  provider     = postgresql.honua
  name         = "postgis_raster"
  schema       = "public"
  drop_cascade = true

  depends_on = [
    module.rds,
    postgresql_extension.postgis,
  ]
}
