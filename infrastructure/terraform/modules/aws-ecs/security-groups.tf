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
    cidr_blocks = local.db_egress_cidrs
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
