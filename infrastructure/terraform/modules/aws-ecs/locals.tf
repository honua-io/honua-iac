locals {
  name = "${var.name_prefix}-${var.environment}"
  tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.tags)
  use_existing_vpc      = var.existing_vpc_id != ""
  vpc_id                = local.use_existing_vpc ? var.existing_vpc_id : module.vpc[0].vpc_id
  vpc_cidr_block        = local.use_existing_vpc ? var.existing_vpc_cidr : module.vpc[0].vpc_cidr_block
  public_subnets        = local.use_existing_vpc ? var.existing_public_subnet_ids : module.vpc[0].public_subnets
  private_subnets       = local.use_existing_vpc ? var.existing_private_subnet_ids : module.vpc[0].private_subnets
  db_use_existing       = var.existing_db_endpoint != "" && var.existing_db_connection_string != ""
  db_egress_cidrs       = distinct(local.db_use_existing ? var.existing_db_cidrs : [local.vpc_cidr_block])
  use_managed_cert      = var.domain_name != "" && var.route53_zone_id != ""
  use_https             = var.alb_certificate_arn != "" || local.use_managed_cert
  default_ingress_cidrs = [local.vpc_cidr_block]
  https_ingress_cidrs = length(var.allow_public_ingress_cidrs) > 0 ? var.allow_public_ingress_cidrs : (
    length(var.allow_https_ingress_cidrs) > 0 ? var.allow_https_ingress_cidrs : (local.use_https ? local.default_ingress_cidrs : [])
  )
  http_ingress_base = length(var.allow_http_ingress_cidrs) > 0 ? var.allow_http_ingress_cidrs : (
    length(local.https_ingress_cidrs) > 0 ? local.https_ingress_cidrs : (!local.use_https ? local.default_ingress_cidrs : [])
  )
  http_ingress_cidrs               = local.use_https ? (var.alb_enable_http_redirect ? local.http_ingress_base : []) : local.http_ingress_base
  redis_enabled                    = var.redis_enabled || var.redis_connection_string != ""
  redis_create                     = var.redis_enabled && var.redis_connection_string == ""
  redis_auth_token                 = var.redis_auth_token != "" ? var.redis_auth_token : (local.redis_create ? random_password.redis_auth[0].result : "")
  redis_connection                 = var.redis_connection_string != "" ? var.redis_connection_string : (local.redis_create ? "${aws_elasticache_replication_group.redis[0].primary_endpoint_address}:${var.redis_port},password=${local.redis_auth_token},ssl=true" : "")
  connection_encryption_master_key = var.connection_encryption_master_key != null ? var.connection_encryption_master_key : random_password.connection_encryption_master_key[0].result
  redis_egress_cidrs               = local.redis_create ? [local.vpc_cidr_block] : var.redis_connection_cidrs
  db_subnet_ids                    = var.db_publicly_accessible ? local.public_subnets : local.private_subnets
  canary_enabled                   = var.canary_enabled
  canary_weight                    = local.canary_enabled ? var.canary_weight_percentage : 0
  primary_weight                   = local.canary_enabled ? 100 - local.canary_weight : 100
  effective_canary_image           = trimspace(var.canary_image) != "" ? var.canary_image : var.image
  execution_role_image_uris = distinct(compact([
    trimspace(var.image),
    local.canary_enabled ? trimspace(local.effective_canary_image) : null
  ]))
  execution_role_ecr_image_matches = {
    for image in local.execution_role_image_uris :
    image => regex("^([0-9]{12})\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com\\/([^@:]+)(?:[:@].+)?$", image)
    if can(regex("^([0-9]{12})\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com\\/([^@:]+)(?:[:@].+)?$", image))
  }
  execution_role_ecr_repository_arns = distinct([
    for image, captures in local.execution_role_ecr_image_matches :
    "arn:${data.aws_partition.current.partition}:ecr:${captures[1]}:${captures[0]}:repository/${captures[2]}"
  ])
  app_storage_prefix = trimprefix(trimsuffix(trimspace(var.app_storage_prefix), "/"), "/")
  app_storage_bucket_name = var.app_storage_enabled ? (
    trimspace(var.app_storage_bucket_name) != ""
    ? lower(trimspace(var.app_storage_bucket_name))
    : substr(replace(lower("${var.name_prefix}-${var.environment}-app-${random_id.app_storage_suffix[0].hex}"), "_", "-"), 0, 63)
  ) : null
  app_storage_environment = var.app_storage_enabled ? {
    FileStorage__Provider                          = "AwsS3"
    FileStorage__AwsS3__BucketName                 = local.app_storage_bucket_name
    FileStorage__AwsS3__Region                     = data.aws_region.current.id
    FileStorage__AwsS3__KeyPrefix                  = local.app_storage_prefix
    FileStorage__AwsS3__EnableServerSideEncryption = "true"
  } : {}
  primary_container_environment = [
    for key, value in merge(local.app_storage_environment, var.additional_env) : {
      name  = key
      value = value
    }
  ]
  canary_container_environment = [
    for key, value in merge(local.app_storage_environment, var.additional_env, var.canary_additional_env) : {
      name  = key
      value = value
    }
  ]
  container_secrets = concat([
    {
      name      = "ConnectionStrings__DefaultConnection"
      valueFrom = aws_secretsmanager_secret.db_connection.arn
    },
    {
      name      = "HONUA_ADMIN_PASSWORD"
      valueFrom = aws_secretsmanager_secret.admin_password.arn
    },
    {
      name      = "Security__ConnectionEncryption__MasterKey"
      valueFrom = aws_secretsmanager_secret.connection_encryption_master_key.arn
    }
    ], local.redis_enabled ? [
    {
      name      = "ConnectionStrings__redis"
      valueFrom = aws_secretsmanager_secret.redis_connection[0].arn
    }
  ] : [])
  container_log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.this.name
      awslogs-region        = data.aws_region.current.id
      awslogs-stream-prefix = "honua"
    }
  }
  container_health_check = {
    command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}${var.health_check_path} || exit 1"]
    interval    = 30
    timeout     = 5
    retries     = 3
    startPeriod = 60
  }
}

locals {
  db_password          = var.db_password != null ? var.db_password : (local.db_use_existing ? var.existing_db_admin_password : random_password.db[0].result)
  db_ssl               = var.db_require_ssl ? ";SSL Mode=Require;Trust Server Certificate=false" : ""
  db_endpoint          = local.db_use_existing ? var.existing_db_endpoint : module.rds[0].db_instance_address
  db_connection_string = local.db_use_existing ? var.existing_db_connection_string : "Host=${local.db_endpoint};Port=5432;Database=${var.db_name};Username=${var.db_username};Password=${local.db_password}${local.db_ssl}"
  kms_key_arn          = var.kms_key_arn != "" ? var.kms_key_arn : aws_kms_key.honua[0].arn
  alb_logs_bucket_name = var.alb_access_logs_bucket_name != "" ? var.alb_access_logs_bucket_name : "${local.name}-alb-logs-${random_id.alb_logs_suffix.hex}"
  certificate_arn      = var.alb_certificate_arn != "" ? var.alb_certificate_arn : (local.use_managed_cert ? aws_acm_certificate_validation.this[0].certificate_arn : "")
}
