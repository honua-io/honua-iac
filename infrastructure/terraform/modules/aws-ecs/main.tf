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
