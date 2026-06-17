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
  use_existing_vpc   = var.existing_vpc_id != ""
  vpc_id             = local.use_existing_vpc ? var.existing_vpc_id : module.vpc[0].vpc_id
  vpc_cidr_block     = local.use_existing_vpc ? var.existing_vpc_cidr : module.vpc[0].vpc_cidr_block
  public_subnets     = local.use_existing_vpc ? var.existing_public_subnet_ids : module.vpc[0].public_subnets
  private_subnets    = local.use_existing_vpc ? var.existing_private_subnet_ids : module.vpc[0].private_subnets
  db_use_existing    = var.existing_db_endpoint != "" && var.existing_db_connection_string != ""
  redis_enabled      = var.redis_enabled || var.redis_connection_string != ""
  redis_create       = var.redis_enabled && var.redis_connection_string == ""
  image_ref          = split("@", var.image)[0]
  image_repo_path    = join("/", slice(split("/", local.image_ref), 1, length(split("/", local.image_ref))))
  image_repo_name    = split(":", local.image_repo_path)[0]
  redis_auth_token   = var.redis_auth_token != "" ? var.redis_auth_token : (local.redis_create ? random_password.redis_auth[0].result : "")
  redis_connection   = var.redis_connection_string != "" ? var.redis_connection_string : (local.redis_create ? "${aws_elasticache_replication_group.redis[0].primary_endpoint_address}:${var.redis_port},password=${local.redis_auth_token},ssl=true" : "")
  redis_egress_cidrs = local.redis_create ? [local.vpc_cidr_block] : var.redis_connection_cidrs
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

resource "random_password" "db" {
  count            = var.db_password == null && !local.db_use_existing ? 1 : 0
  length           = 32
  special          = true
  override_special = "#%*()-_=+[]{}:?"
}

resource "random_password" "redis_auth" {
  count            = local.redis_create && var.redis_auth_token == "" ? 1 : 0
  length           = 32
  special          = true
  override_special = "#%*()-_=+[]{}:?"
}

locals {
  db_password          = var.db_password != null ? var.db_password : (local.db_use_existing ? "" : random_password.db[0].result)
  db_ssl               = var.db_require_ssl ? ";SSL Mode=Require;Trust Server Certificate=false" : ""
  db_endpoint          = local.db_use_existing ? var.existing_db_endpoint : module.rds[0].db_instance_address
  db_conn_options      = var.db_connection_string_options != "" ? ";${var.db_connection_string_options}" : ""
  db_connection_string = local.db_use_existing ? var.existing_db_connection_string : "Host=${local.db_endpoint};Port=5432;Database=${var.db_name};Username=${var.db_username};Password=${local.db_password}${local.db_ssl}${local.db_conn_options}"
  lambda_function_name = "${local.name}-honua"
  lambda_target_id     = "${local.lambda_function_name}-${var.lambda_alias_name}"
  redis_secret_environment = local.redis_connection != "" ? {
    ConnectionStrings__redis       = "env:HONUA_RUNTIME_REDIS_CONNECTION"
    HONUA_RUNTIME_REDIS_CONNECTION = local.redis_connection
  } : {}
  xray_environment = var.enable_xray_tracing ? {
    Tracing__XRay__Enabled = "true"
  # When GP-on-Batch is enabled, surface the queue/job-definition ARNs and
  # default sizing to the server as a ControlPlane:ExecutionWorkloads entry.
  # The reconciler selects the AwsBatchComputeBackend by Backend=honua-aws-batch
  # + TargetKind=AwsBatch; ParameterEntries carry the batch.* keys the backend
  # reads off ExecutionJobSpec.Parameters at submit time.
  gp_batch_environment = local.gp_batch_enabled ? {
    ControlPlane__ExecutionWorkloads__0__WorkloadId                 = var.gp_batch_workload_id
    ControlPlane__ExecutionWorkloads__0__WorkloadName               = var.gp_batch_workload_name
    ControlPlane__ExecutionWorkloads__0__TargetKind                 = "AwsBatch"
    ControlPlane__ExecutionWorkloads__0__Backend                    = "honua-aws-batch"
    ControlPlane__ExecutionWorkloads__0__Kind                       = "Geoprocessing"
    ControlPlane__ExecutionWorkloads__0__ArtifactReference          = local.gp_batch_image
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__0__Key   = "batch.job_queue_arn"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__0__Value = aws_batch_job_queue.gp[0].arn
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__1__Key   = "batch.job_definition_arn"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__1__Value = aws_batch_job_definition.gp[0].arn
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__2__Key   = "batch.region"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__2__Value = data.aws_region.current.name
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__3__Key   = "batch.vcpus"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__3__Value = tostring(var.gp_batch_vcpus)
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__4__Key   = "batch.memory_mib"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__4__Value = tostring(var.gp_batch_memory_mib)
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__5__Key   = "batch.timeout_seconds"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__5__Value = tostring(var.gp_batch_timeout_seconds)
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__6__Key   = "batch.retry_attempts"
    ControlPlane__ExecutionWorkloads__0__ParameterEntries__6__Value = tostring(var.gp_batch_retry_attempts)
  } : {}
  lambda_environment = merge({
    HONUA_SKIP_MIGRATIONS                                       = var.skip_migrations ? "true" : "false"
    HostValidation__AllowedHosts__0                             = "*.execute-api.${data.aws_region.current.name}.amazonaws.com"
    ConnectionStrings__DefaultConnection                        = "aws:secretsmanager:${aws_secretsmanager_secret.connection_string.arn}"
    HONUA_ADMIN_PASSWORD                                        = "aws:secretsmanager:${aws_secretsmanager_secret.admin_password.arn}"
    Security__ConnectionEncryption__MasterKey                   = "aws:secretsmanager:${aws_secretsmanager_secret.admin_password.arn}"
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
    ControlPlane__DeployTargets__0__ParameterEntries__2__Value  = data.aws_region.current.name
  }, local.gp_batch_environment, var.additional_env, local.redis_secret_environment, local.xray_environment)
}

#checkov:skip=CKV_TF_1: Registry modules are version-pinned.
module "vpc" {
  count = local.use_existing_vpc ? 0 : 1
  #checkov:skip=CKV_TF_1: Registry modules are version-pinned.
  #checkov:skip=CKV2_AWS_12: Default SG is managed via module inputs.
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

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
      cidr_blocks = ["0.0.0.0/0"]
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

resource "aws_security_group" "redis" {
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
  max_allocated_storage = 100
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
  apply_immediately   = var.db_apply_immediately

  backup_retention_period = var.environment == "prod" ? 7 : 3
  maintenance_window      = "Sun:04:00-Sun:05:00"

  tags = local.tags
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

data "aws_ecr_repository" "image" {
  name = local.image_repo_name
}

data "aws_iam_policy_document" "lambda_ecr_access" {
  statement {
    sid    = "AllowLambdaImageRetrieval"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]

    condition {
      test     = "StringLike"
      variable = "aws:sourceArn"
      values = [
        "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:*"
      ]
    }
  }
}

resource "aws_ecr_repository_policy" "lambda_image_access" {
  repository = data.aws_ecr_repository.image.name
  policy     = data.aws_iam_policy_document.lambda_ecr_access.json
}

resource "aws_iam_role" "lambda" {
  name_prefix        = "${local.name}-lambda-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_policy" "lambda_secrets" {
  name = "${local.name}-lambda-secrets"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = compact([
          aws_secretsmanager_secret.connection_string.arn,
          aws_secretsmanager_secret.admin_password.arn,
          local.redis_enabled ? aws_secretsmanager_secret.redis_connection[0].arn : null
        ])
      }
    ]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "lambda_secrets" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_secrets.arn
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
resource "aws_secretsmanager_secret" "connection_string" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is managed outside this module.
  name        = "${local.name}/connection-string"
  description = "Database connection string for Honua."
  tags        = local.tags
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
#checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
resource "aws_cloudwatch_log_group" "lambda" {
  #checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
  #checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
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

  dynamic "tracing_config" {
    for_each = var.enable_xray_tracing ? [1] : []
    content {
      mode = "Active"
    }
  }

  environment {
    variables = local.lambda_environment
  }

  depends_on = [
    aws_ecr_repository_policy.lambda_image_access,
    aws_cloudwatch_log_group.lambda,
    aws_secretsmanager_secret_version.connection_string,
    aws_secretsmanager_secret_version.admin_password,
    aws_secretsmanager_secret_version.redis_connection
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
#checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
resource "aws_cloudwatch_log_group" "api_gateway" {
  #checkov:skip=CKV_AWS_158: Log-group KMS integration is optional and supplied by the deployment environment.
  #checkov:skip=CKV_AWS_338: Retention period is caller-configurable; demo environments intentionally use shorter retention to manage cost.
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

resource "null_resource" "enable_postgis" {
  count = var.enable_postgis && !local.db_use_existing ? 1 : 0

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
    }
  }

  depends_on = [module.rds]
}
