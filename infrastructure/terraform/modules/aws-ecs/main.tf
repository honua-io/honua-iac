data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_elb_service_account" "current" {}

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

#checkov:skip=CKV_TF_1: Registry modules are version-pinned.
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

resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5: Security group is attached to the ALB.
  #checkov:skip=CKV_AWS_260: HTTP ingress is optional and disabled by default.
  name_prefix = "${local.name}-alb-"
  description = "ALB security group"
  vpc_id      = local.vpc_id

  dynamic "ingress" {
    for_each = length(local.http_ingress_cidrs) > 0 ? [1] : []
    content {
      description = "HTTP ingress"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = local.http_ingress_cidrs
    }
  }

  dynamic "ingress" {
    for_each = local.use_https ? [1] : []
    content {
      description = "HTTPS ingress"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = local.https_ingress_cidrs
    }
  }

  egress {
    description = "ALB to ECS targets"
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  tags = local.tags
}

#checkov:skip=CKV2_AWS_5: Security group is attached to the ECS service.
resource "aws_security_group" "ecs" {
  #checkov:skip=CKV2_AWS_5: Security group is attached to the ECS service.
  name_prefix = "${local.name}-ecs-"
  description = "ECS service security group"
  vpc_id      = local.vpc_id

  ingress {
    description     = "ALB ingress"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Database access"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = local.db_use_existing ? var.existing_db_cidrs : [local.vpc_cidr_block]
  }

  egress {
    description = "Outbound HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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

  tags = local.tags
}

#checkov:skip=CKV2_AWS_5: Security group is attached to the RDS instance.
resource "aws_security_group" "rds" {
  count = local.db_use_existing ? 0 : 1
  #checkov:skip=CKV2_AWS_5: Security group is attached via the RDS module.
  name_prefix = "${local.name}-rds-"
  description = "RDS security group"
  vpc_id      = local.vpc_id

  ingress {
    description     = "PostgreSQL from ECS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
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
}

#checkov:skip=CKV2_AWS_5: Security group is attached through the replication group below.
resource "aws_security_group" "redis" {
  #checkov:skip=CKV2_AWS_5: Security group is attached through the replication group below.
  count       = local.redis_create ? 1 : 0
  name_prefix = "${local.name}-redis-"
  description = "Redis security group"
  vpc_id      = local.vpc_id

  ingress {
    description     = "Redis from ECS"
    from_port       = var.redis_port
    to_port         = var.redis_port
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    description = "Redis outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr_block]
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
  automatic_failover_enabled = var.redis_num_cache_clusters > 1
  multi_az_enabled           = var.redis_num_cache_clusters > 1
  num_cache_clusters         = var.redis_num_cache_clusters
  subnet_group_name          = aws_elasticache_subnet_group.redis[0].name
  security_group_ids         = [aws_security_group.redis[0].id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = local.redis_auth_token
  kms_key_id                 = local.kms_key_arn
  apply_immediately          = true
  tags                       = local.tags

  lifecycle {
    precondition {
      condition     = var.redis_num_cache_clusters >= 1
      error_message = "redis_num_cache_clusters must be >= 1."
    }
  }
}

#checkov:skip=CKV2_AWS_28: WAF association is optional via waf_web_acl_arn.
resource "aws_lb" "this" {
  #checkov:skip=CKV2_AWS_76: WAF AMR configuration is managed via waf_web_acl_arn association.
  #checkov:skip=CKV2_AWS_20: HTTP redirect is conditional based on certificate availability.
  name                       = "${local.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = local.public_subnets
  enable_deletion_protection = var.alb_deletion_protection
  drop_invalid_header_fields = var.alb_drop_invalid_headers

  access_logs {
    enabled = var.alb_access_logs_enabled
    bucket  = local.alb_logs_bucket_name
    prefix  = var.alb_access_logs_prefix
  }

  # Ensure bucket policy is in place before ALB logging is configured.
  depends_on = [aws_s3_bucket_policy.alb_logs]

  tags = local.tags
}

resource "aws_wafv2_web_acl_association" "this" {
  count        = var.waf_web_acl_arn != "" ? 1 : 0
  resource_arn = aws_lb.this.arn
  web_acl_arn  = var.waf_web_acl_arn
}

resource "aws_acm_certificate" "this" {
  count                     = local.use_managed_cert ? 1 : 0
  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"
  tags                      = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.use_managed_cert ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.use_managed_cert ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_s3_bucket" "alb_logs" {
  #checkov:skip=CKV_AWS_18: Access log bucket doesn't require its own access logs.
  #checkov:skip=CKV2_AWS_62: Event notifications are optional for log buckets.
  #checkov:skip=CKV2_AWS_61: Lifecycle policies are optional for log buckets.
  #checkov:skip=CKV_AWS_144: Cross-region replication is optional for log buckets.
  #checkov:skip=CKV_AWS_145: Encryption enforced via separate configuration resource.
  #checkov:skip=CKV_AWS_21: Versioning enforced via separate configuration resource.
  #checkov:skip=CKV2_AWS_6: Public access block enforced via separate resource.
  count         = var.alb_access_logs_enabled && var.alb_access_logs_bucket_name == "" ? 1 : 0
  bucket        = local.alb_logs_bucket_name
  force_destroy = var.alb_access_logs_force_destroy
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  count                   = var.alb_access_logs_enabled && var.alb_access_logs_bucket_name == "" ? 1 : 0
  bucket                  = aws_s3_bucket.alb_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  count  = var.alb_access_logs_enabled && var.alb_access_logs_bucket_name == "" ? 1 : 0
  bucket = aws_s3_bucket.alb_logs[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  count  = var.alb_access_logs_enabled && var.alb_access_logs_bucket_name == "" ? 1 : 0
  bucket = aws_s3_bucket.alb_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  count  = var.alb_access_logs_enabled && var.alb_access_logs_bucket_name == "" ? 1 : 0
  bucket = aws_s3_bucket.alb_logs[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  count  = var.alb_access_logs_enabled && var.alb_access_logs_bucket_name == "" ? 1 : 0
  bucket = aws_s3_bucket.alb_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS     = data.aws_elb_service_account.current.arn
          Service = "logdelivery.elasticloadbalancing.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs[0].arn}/${var.alb_access_logs_prefix != "" ? "${var.alb_access_logs_prefix}/" : ""}AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Effect = "Allow"
        Principal = {
          AWS     = data.aws_elb_service_account.current.arn
          Service = "logdelivery.elasticloadbalancing.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.alb_logs[0].arn
      }
    ]
  })
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

resource "aws_s3_bucket_ownership_controls" "app_storage" {
  count = var.app_storage_enabled ? 1 : 0

  bucket = aws_s3_bucket.app_storage[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
#checkov:skip=CKV_AWS_378: Target group uses HTTP for in-VPC traffic.
resource "aws_lb_target_group" "this" {
  #checkov:skip=CKV_AWS_378: Target group uses HTTP for in-VPC traffic.
  name        = "${local.name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200-399"
  }

  tags = local.tags
}

#checkov:skip=CKV_AWS_378: Target group uses HTTP for in-VPC traffic, matching the primary service target group.
resource "aws_lb_target_group" "canary" {
  #checkov:skip=CKV_AWS_378: Target group uses HTTP for in-VPC traffic, matching the primary service target group.
  count       = local.canary_enabled ? 1 : 0
  name        = substr("${local.name}-canary-tg", 0, 32)
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_check_path
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200-399"
  }

  tags = merge(local.tags, {
    DeploymentSlot = "canary"
  })
}

resource "aws_lb_listener" "https" {
  count             = local.use_https ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.certificate_arn

  dynamic "default_action" {
    for_each = local.canary_enabled ? [1] : []
    content {
      type = "forward"

      forward {
        target_group {
          arn    = aws_lb_target_group.this.arn
          weight = local.primary_weight
        }

        target_group {
          arn    = aws_lb_target_group.canary[0].arn
          weight = local.canary_weight
        }
      }
    }
  }

  dynamic "default_action" {
    for_each = local.canary_enabled ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this.arn
    }
  }
}

resource "aws_lb_listener" "http_redirect" {
  #checkov:skip=CKV_AWS_2: HTTP listener is used for redirect to HTTPS.
  #checkov:skip=CKV_AWS_103: HTTP listener is required for redirect when HTTPS is enabled.
  count             = local.use_https && var.alb_enable_http_redirect && length(local.http_ingress_cidrs) > 0 ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2: HTTP listener is used when no HTTPS certificate is configured.
  #checkov:skip=CKV_AWS_103: HTTP listener is required when no HTTPS certificate is configured.
  count             = local.use_https ? 0 : (length(local.http_ingress_cidrs) > 0 ? 1 : 0)
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.canary_enabled ? [1] : []
    content {
      type = "forward"

      forward {
        target_group {
          arn    = aws_lb_target_group.this.arn
          weight = local.primary_weight
        }

        target_group {
          arn    = aws_lb_target_group.canary[0].arn
          weight = local.canary_weight
        }
      }
    }
  }

  dynamic "default_action" {
    for_each = local.canary_enabled ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this.arn
    }
  }
}

resource "aws_lb_listener_rule" "https_canary" {
  count        = local.canary_enabled && local.use_https ? 1 : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = var.canary_listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.canary[0].arn
  }

  condition {
    http_header {
      http_header_name = var.canary_header_name
      values           = [var.canary_header_value]
    }
  }
}

resource "aws_lb_listener_rule" "http_canary" {
  count        = local.canary_enabled && !local.use_https && length(local.http_ingress_cidrs) > 0 ? 1 : 0
  listener_arn = aws_lb_listener.http[0].arn
  priority     = var.canary_listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.canary[0].arn
  }

  condition {
    http_header {
      http_header_name = var.canary_header_name
      values           = [var.canary_header_value]
    }
  }
}

resource "aws_ecs_cluster" "this" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/honua/${local.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = local.kms_key_arn
  tags              = local.tags
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "task_execution_runtime" {
  statement {
    sid = "WriteContainerLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  dynamic "statement" {
    for_each = length(local.execution_role_ecr_repository_arns) > 0 ? [1] : []

    content {
      sid       = "AuthorizeEcrPull"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = length(local.execution_role_ecr_repository_arns) > 0 ? [1] : []

    content {
      sid = "ReadEcrImages"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ]
      resources = local.execution_role_ecr_repository_arns
    }
  }
}

resource "aws_iam_policy" "task_execution_runtime" {
  name        = "${local.name}-task-execution-runtime"
  description = "Least-privilege ECS task execution policy for logs and image pulls"
  policy      = data.aws_iam_policy_document.task_execution_runtime.json
}

resource "aws_iam_role_policy_attachment" "task_execution_runtime" {
  role       = aws_iam_role.task_execution.name
  policy_arn = aws_iam_policy.task_execution_runtime.arn
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
  tags               = local.tags
}

resource "aws_iam_policy" "secrets" {
  name        = "${local.name}-secrets"
  description = "Allow ECS task to read Honua secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = compact([
          aws_secretsmanager_secret.db_connection.arn,
          aws_secretsmanager_secret.admin_password.arn,
          aws_secretsmanager_secret.connection_encryption_master_key.arn,
          local.redis_enabled ? aws_secretsmanager_secret.redis_connection[0].arn : null
        ])
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [local.kms_key_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "task_secrets" {
  role       = aws_iam_role.task_execution.name
  policy_arn = aws_iam_policy.secrets.arn
}

resource "aws_iam_policy" "task_app_storage" {
  count = var.app_storage_enabled ? 1 : 0

  name        = "${local.name}-task-app-storage"
  description = "Allow ECS task to read and write Honua application storage"

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
}

resource "aws_iam_role_policy_attachment" "task_app_storage" {
  count = var.app_storage_enabled ? 1 : 0

  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.task_app_storage[0].arn
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
  override_special = "#%*()-_=+[]{}:?."

  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

resource "random_id" "alb_logs_suffix" {
  byte_length = 4
}

resource "random_id" "app_storage_suffix" {
  count       = var.app_storage_enabled && trimspace(var.app_storage_bucket_name) == "" ? 1 : 0
  byte_length = 4
}

data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_111: Root access is required for KMS administration.
  #checkov:skip=CKV_AWS_356: Root access is required for KMS administration.
  #checkov:skip=CKV_AWS_109: Root access is required for KMS administration.
  statement {
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowCloudWatchLogsUse"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.id}.amazonaws.com"]
    }
  }

  statement {
    sid       = "AllowSecretsManagerUse"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["secretsmanager.${data.aws_region.current.id}.amazonaws.com"]
    }
  }

  statement {
    sid       = "AllowElastiCacheUse"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant", "kms:RetireGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ViaService"
      values = [
        "elasticache.${data.aws_region.current.id}.amazonaws.com",
        "dax.${data.aws_region.current.id}.amazonaws.com"
      ]
    }
  }

  statement {
    sid       = "AllowEcsTaskExecutionDecrypt"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.task_execution.arn]
    }
  }
}

resource "aws_kms_key" "honua" {
  count                   = var.kms_key_arn == "" ? 1 : 0
  description             = "Honua infrastructure key"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = local.tags
}

resource "aws_kms_alias" "honua" {
  count         = var.kms_key_arn == "" ? 1 : 0
  name          = "alias/${local.name}-honua"
  target_key_id = aws_kms_key.honua[0].key_id
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

#checkov:skip=CKV_TF_1: Registry modules are version-pinned.
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

#checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
resource "aws_secretsmanager_secret" "db_connection" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
  name_prefix = "${local.name}-db-"
  description = "Honua database connection string"
  kms_key_id  = local.kms_key_arn
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "db_connection" {
  secret_id     = aws_secretsmanager_secret.db_connection.id
  secret_string = local.db_connection_string
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
resource "aws_secretsmanager_secret" "admin_password" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
  name_prefix = "${local.name}-admin-"
  description = "Honua admin API password"
  kms_key_id  = local.kms_key_arn
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "admin_password" {
  secret_id     = aws_secretsmanager_secret.admin_password.id
  secret_string = var.admin_password
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
resource "aws_secretsmanager_secret" "connection_encryption_master_key" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
  name_prefix = "${local.name}-master-key-"
  description = "Honua connection encryption master key"
  kms_key_id  = local.kms_key_arn
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "connection_encryption_master_key" {
  secret_id     = aws_secretsmanager_secret.connection_encryption_master_key.id
  secret_string = local.connection_encryption_master_key
}

#checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
resource "aws_secretsmanager_secret" "redis_connection" {
  #checkov:skip=CKV2_AWS_57: Secrets rotation is handled outside the module.
  count       = local.redis_enabled ? 1 : 0
  name_prefix = "${local.name}-redis-"
  description = "Honua Redis connection string"
  kms_key_id  = local.kms_key_arn
  tags        = local.tags
}

resource "aws_secretsmanager_secret_version" "redis_connection" {
  count         = local.redis_enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.redis_connection[0].id
  secret_string = local.redis_connection
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${local.name}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.container_cpu
  memory                   = var.container_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = upper(var.task_cpu_architecture)
  }

  container_definitions = jsonencode([
    {
      name      = "honua"
      image     = var.image
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]
      environment      = local.primary_container_environment
      secrets          = local.container_secrets
      logConfiguration = local.container_log_configuration
      healthCheck      = local.container_health_check
    }
  ])

  depends_on = [
    aws_secretsmanager_secret_version.db_connection,
    aws_secretsmanager_secret_version.admin_password,
    aws_secretsmanager_secret_version.connection_encryption_master_key,
    aws_secretsmanager_secret_version.redis_connection
  ]

  tags = local.tags
}

resource "aws_ecs_task_definition" "canary" {
  count                    = local.canary_enabled ? 1 : 0
  family                   = "${local.name}-canary-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.container_cpu
  memory                   = var.container_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = upper(var.task_cpu_architecture)
  }

  container_definitions = jsonencode([
    {
      name      = "honua"
      image     = local.effective_canary_image
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]
      environment      = local.canary_container_environment
      secrets          = local.container_secrets
      logConfiguration = local.container_log_configuration
      healthCheck      = local.container_health_check
    }
  ])

  depends_on = [
    aws_secretsmanager_secret_version.db_connection,
    aws_secretsmanager_secret_version.admin_password,
    aws_secretsmanager_secret_version.connection_encryption_master_key,
    aws_secretsmanager_secret_version.redis_connection
  ]

  tags = merge(local.tags, {
    DeploymentSlot = "canary"
  })
}

resource "aws_ecs_service" "this" {
  name            = "${local.name}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.private_subnets
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "honua"
    container_port   = var.container_port
  }

  depends_on = [aws_lb_listener.https, aws_lb_listener.http, aws_lb_listener.http_redirect]

  tags = local.tags
}

resource "aws_ecs_service" "canary" {
  count           = local.canary_enabled ? 1 : 0
  name            = "${local.name}-canary-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.canary[0].arn
  desired_count   = var.canary_desired_count
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = local.private_subnets
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.canary[0].arn
    container_name   = "honua"
    container_port   = var.container_port
  }

  depends_on = [aws_lb_listener.https, aws_lb_listener.http, aws_lb_listener.http_redirect]

  tags = merge(local.tags, {
    DeploymentSlot = "canary"
  })
}

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity != null ? var.min_capacity : var.desired_count
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = var.autoscaling_cpu_target_value
    scale_in_cooldown  = var.autoscaling_scale_in_cooldown_seconds
    scale_out_cooldown = var.autoscaling_scale_out_cooldown_seconds
  }
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

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
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
