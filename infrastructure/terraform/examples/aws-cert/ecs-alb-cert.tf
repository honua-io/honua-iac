###############################################################################
# ECS/ALB weighted-cutover certification cell — examples/aws-cert
# (honua-io/honua-server#2164)
#
# OPT-IN (enable_ecs_alb_cert, default false; billable while on). Provisions the
# MINIMAL standing substrate the server's production AwsEcsAlbDeployBackend
# certifies against REAL AWS ELBv2 + ECS APIs: an internal ALB whose listener
# default rule is a WEIGHTED forward across a stable + a canary target group,
# and one Fargate ECS service attached to BOTH target groups.
#
# Design — single service, dual target group. One ECS service registers with
# BOTH target groups (two load_balancer blocks) so both always carry the same
# healthy tasks. The weight-shift the backend performs (ModifyRule/ModifyListener
# to move the stable/canary weights, then ecs UpdateService + convergence
# observation, then restore weights to roll back) is therefore a PURE ALB-level
# cutover — it certifies the weight mechanics + service convergence + rollback
# WITHOUT needing two service revisions. The two-revision (blue/green with a
# distinct canary task set) variant is honua-server#2165 territory, not this cell.
#
# Internal ALB — internal = true. The cert tests drive the AWS control-plane
# APIs (ELBv2 ModifyRule/ModifyListener/DescribeRules, ECS UpdateService/
# DescribeServices), NOT the HTTP data path, so the ALB needs no public
# exposure; an internal scheme keeps the cell off the public internet.
#
# Image — public.ecr.aws/nginx/nginx:stable-alpine. A tiny, long-term-stable,
# unauthenticated public image that serves HTTP 200 on "/" at port 80, so the
# target-group health checks pass and the tasks converge to healthy without any
# Honua build. Pulled over the base cert stack's existing NAT egress from the
# module's private subnets (assign_public_ip = false).
#
# VPC — reuses module.honua's VPC/private subnets (vpc_id, private_subnet_ids,
# vpc_cidr_block outputs). No new VPC, NAT, or subnets are minted for the cell.
###############################################################################

locals {
  ecs_alb_enabled = var.enable_ecs_alb_cert
  ecs_alb_name    = "${local.name}-cutover"
  # nginx:stable-alpine serves HTTP 200 on "/" — the health-check + evidence path.
  ecs_alb_image = var.ecs_alb_image

  # Serving mode (var.ecs_alb_serve_honua): Honua listens on 8080 and exposes
  # /healthz/live; the fixture listens on 80 and answers "/".
  ecs_alb_honua             = var.ecs_alb_serve_honua
  ecs_alb_container_port    = local.ecs_alb_honua ? 8080 : 80
  ecs_alb_health_check_path = local.ecs_alb_honua ? "/healthz/live" : "/"
  ecs_alb_public            = var.ecs_alb_internet_facing
  ecs_alb_ingress_cidrs     = local.ecs_alb_public && length(var.ecs_alb_ingress_cidrs) > 0 ? var.ecs_alb_ingress_cidrs : [module.honua.vpc_cidr_block]

  # The same secrets the standing certification Lambda resolves at startup,
  # injected by the ECS agent (execution role) rather than resolved in-process.
  ecs_alb_honua_secrets = {
    ConnectionStrings__DefaultConnection                = module.honua.db_connection_secret_arn
    ConnectionStrings__redis                            = module.honua.redis_connection_secret_arn
    HONUA_ADMIN_PASSWORD                                = module.honua.admin_password_secret_arn
    Security__ConnectionEncryption__MasterKey           = module.honua.master_key_secret_arn
    Operations__SecretChannel__KeyRingCertificatePkcs12 = module.honua.operation_key_ring_certificate_secret_arn
  }
  ecs_alb_honua_environment = {
    HONUA_ADMIN_UI                  = "false"
    HONUA_SERVE_ADMIN_UI            = "false"
    HONUA_OBSERVABILITY             = "true"
    Licensing__Mode                 = "Disabled"
    SecurityHeaders__HstsHttpsOnly  = "false"
    HostValidation__AllowedHosts__0 = "*.elb.amazonaws.com"
  }
}

# ---------------------------------------------------------------------------
# ECS cluster (Fargate only — no standing EC2 capacity).
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "cert_cutover" {
  count = local.ecs_alb_enabled ? 1 : 0
  name  = "${local.ecs_alb_name}-cluster"

  setting {
    name = "containerInsights"
    # Disabled: cost-avoidance for the idle cell; the cert path reads ECS/ELB
    # control-plane APIs, not Container Insights metrics.
    value = "disabled"
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "cert_cutover" {
  #checkov:skip=CKV_AWS_158: SSE-S3/CloudWatch default encryption is sufficient for the ephemeral cert cell's nginx logs; a customer-managed KMS CMK is not warranted here.
  #checkov:skip=CKV_AWS_338: 30-day retention is intentional for the short-lived cert cell (mirrors the stack's log_retention_days); a 1-year floor is not warranted.
  count             = local.ecs_alb_enabled ? 1 : 0
  name              = "/honua/${local.ecs_alb_name}"
  retention_in_days = 30
  tags              = local.tags
}

# ---------------------------------------------------------------------------
# Task execution role — ECR pull (public image needs none, but the AWS-managed
# policy also grants CloudWatch Logs writes the awslogs driver requires).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cert_cutover_assume" {
  count = local.ecs_alb_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cert_cutover_execution" {
  count              = local.ecs_alb_enabled ? 1 : 0
  name               = "${local.ecs_alb_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.cert_cutover_assume[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "cert_cutover_execution" {
  count      = local.ecs_alb_enabled ? 1 : 0
  role       = aws_iam_role.cert_cutover_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Serving mode only: the ECS agent resolves the container's secrets with the
# execution role. Exactly the cert stack's own secret ARNs, no wildcard.
data "aws_iam_policy_document" "cert_cutover_execution_secrets" {
  count = local.ecs_alb_enabled && local.ecs_alb_honua ? 1 : 0

  statement {
    sid       = "CutoverHonuaSecretsRead"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = compact(values(local.ecs_alb_honua_secrets))
  }
}

resource "aws_iam_role_policy" "cert_cutover_execution_secrets" {
  count  = local.ecs_alb_enabled && local.ecs_alb_honua ? 1 : 0
  name   = "${local.ecs_alb_name}-exec-secrets"
  role   = aws_iam_role.cert_cutover_execution[0].id
  policy = data.aws_iam_policy_document.cert_cutover_execution_secrets[0].json
}

# ---------------------------------------------------------------------------
# Security groups — internal ALB fronting the Fargate tasks.
# ---------------------------------------------------------------------------

resource "aws_security_group" "cert_cutover_alb" {
  #checkov:skip=CKV2_AWS_5: Attached to the internal cert ALB (aws_lb.cert_cutover).
  count       = local.ecs_alb_enabled ? 1 : 0
  name_prefix = "${local.ecs_alb_name}-alb-"
  description = "Internal cert cutover ALB security group (HTTP 80 from within the VPC)"
  vpc_id      = module.honua.vpc_id

  ingress {
    #checkov:skip=CKV_AWS_260: Internet ingress only when ecs_alb_internet_facing is set, for the GitHub-hosted serving certification; the cert server authenticates admin requests itself.
    description = local.ecs_alb_public ? "HTTP from the serving-certification CIDRs" : "HTTP from within the VPC (internal ALB; cert drives control-plane APIs, not this data path)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = local.ecs_alb_ingress_cidrs
  }

  egress {
    description     = "ALB to ECS targets on the container port"
    from_port       = local.ecs_alb_container_port
    to_port         = local.ecs_alb_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.cert_cutover_ecs[0].id]
  }

  tags = local.tags
}

resource "aws_security_group" "cert_cutover_ecs" {
  #checkov:skip=CKV2_AWS_5: Attached to the cert cutover ECS service (aws_ecs_service.cert_cutover).
  count       = local.ecs_alb_enabled ? 1 : 0
  name_prefix = "${local.ecs_alb_name}-ecs-"
  description = "Cert cutover Fargate task security group"
  vpc_id      = module.honua.vpc_id

  egress {
    #checkov:skip=CKV_AWS_382: HTTPS egress to pull the public nginx image over the stack's existing NAT; the task runs a static public image and needs outbound 443 to the ECR/registry endpoints, which are not fixed CIDRs.
    description = "HTTPS egress for public image pull via the stack NAT"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS (UDP) for image-registry resolution"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [module.honua.vpc_cidr_block]
  }

  egress {
    description = "DNS (TCP) for image-registry resolution"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [module.honua.vpc_cidr_block]
  }

  # Serving mode: the Honua task reaches the cert PostGIS and Redis. Their
  # security groups admit the module's Lambda security group, which the service
  # also carries in this mode (see aws_ecs_service.cert_cutover).
  dynamic "egress" {
    for_each = local.ecs_alb_honua ? { "PostgreSQL" = 5432, "Redis" = 6379 } : {}
    content {
      description = "${egress.key} to the cert stack within the VPC"
      from_port   = egress.value
      to_port     = egress.value
      protocol    = "tcp"
      cidr_blocks = [module.honua.vpc_cidr_block]
    }
  }

  tags = local.tags
}

# Separate ingress rule (avoids an SG-to-SG dependency cycle with the ALB SG).
resource "aws_security_group_rule" "cert_cutover_ecs_from_alb" {
  count                    = local.ecs_alb_enabled ? 1 : 0
  type                     = "ingress"
  description              = "ALB to task on container port ${local.ecs_alb_container_port}"
  from_port                = local.ecs_alb_container_port
  to_port                  = local.ecs_alb_container_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cert_cutover_ecs[0].id
  source_security_group_id = aws_security_group.cert_cutover_alb[0].id
}

# ---------------------------------------------------------------------------
# Internal ALB + weighted listener across the stable/canary target groups.
# ---------------------------------------------------------------------------

resource "aws_lb" "cert_cutover" {
  #checkov:skip=CKV2_AWS_28: Internal-only cert ALB (not internet-facing); a WAF web ACL is not warranted for the control-plane certification cell.
  #checkov:skip=CKV2_AWS_20: HTTP-only by design — the internal cell certifies ELBv2/ECS control-plane APIs, not the encrypted HTTP data path, so there is no HTTPS listener to redirect to.
  #checkov:skip=CKV_AWS_150: Deletion protection is intentionally off so the ephemeral cert cell tears down cleanly.
  #checkov:skip=CKV_AWS_91: Access logging omitted for the ephemeral internal cert ALB; the cell certifies control-plane APIs, not HTTP traffic, and carries no evidence value.
  count              = local.ecs_alb_enabled ? 1 : 0
  name               = "${local.ecs_alb_name}-alb"
  load_balancer_type = "application"
  internal           = !local.ecs_alb_public
  security_groups    = [aws_security_group.cert_cutover_alb[0].id]
  subnets            = local.ecs_alb_public ? module.honua.public_subnet_ids : module.honua.private_subnet_ids

  lifecycle {
    precondition {
      condition     = !local.ecs_alb_public || length(module.honua.public_subnet_ids) >= 2
      error_message = "ecs_alb_internet_facing requires the module-managed VPC's public subnets."
    }
  }
  enable_deletion_protection = false
  drop_invalid_header_fields = true

  tags = local.tags
}

resource "aws_lb_target_group" "cert_cutover_stable" {
  #checkov:skip=CKV_AWS_378: HTTP target group for in-VPC traffic to the nginx health endpoint; TLS terminates upstream and is out of scope for the control-plane cert cell.
  count       = local.ecs_alb_enabled ? 1 : 0
  name        = substr("${local.ecs_alb_name}-stable", 0, 32)
  port        = 80
  protocol    = "HTTP"
  vpc_id      = module.honua.vpc_id
  target_type = "ip"

  health_check {
    path                = local.ecs_alb_health_check_path
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200-399"
  }

  tags = merge(local.tags, { DeploymentSlot = "stable" })
}

resource "aws_lb_target_group" "cert_cutover_canary" {
  #checkov:skip=CKV_AWS_378: HTTP target group for in-VPC traffic to the nginx health endpoint; matches the stable target group.
  count       = local.ecs_alb_enabled ? 1 : 0
  name        = substr("${local.ecs_alb_name}-canary", 0, 32)
  port        = 80
  protocol    = "HTTP"
  vpc_id      = module.honua.vpc_id
  target_type = "ip"

  health_check {
    path                = local.ecs_alb_health_check_path
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200-399"
  }

  tags = merge(local.tags, { DeploymentSlot = "canary" })
}

# Listener default rule = weighted forward. Stable starts at 100, canary at 0;
# the backend rewrites these weights to certify the cutover, then restores them.
resource "aws_lb_listener" "cert_cutover" {
  #checkov:skip=CKV_AWS_2: HTTP listener by design — the internal cert cell certifies ELBv2/ECS control-plane APIs, not the encrypted HTTP data path.
  #checkov:skip=CKV_AWS_103: TLS 1.2+ listener not applicable; the cell is an internal HTTP control-plane certification target.
  count             = local.ecs_alb_enabled ? 1 : 0
  load_balancer_arn = aws_lb.cert_cutover[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.cert_cutover_stable[0].arn
        weight = 100
      }

      target_group {
        arn    = aws_lb_target_group.cert_cutover_canary[0].arn
        weight = 0
      }
    }
  }

  # The backend rewrites the weighted forward action; ignore drift so a later
  # terraform apply does not fight an in-progress or mid-rollback cert run.
  lifecycle {
    ignore_changes = [default_action]
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Smallest Fargate task (0.25 vCPU / 512 MB) running the public nginx image.
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "cert_cutover" {
  lifecycle {
    precondition {
      condition     = var.ecs_alb_image != ""
      error_message = "enable_ecs_alb_cert requires a digest-pinned ecs_alb_image serving HTTP on port 80."
    }
  }
  count                    = local.ecs_alb_enabled ? 1 : 0
  family                   = "${local.ecs_alb_name}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = local.ecs_alb_honua ? "1024" : "256"
  memory                   = local.ecs_alb_honua ? "2048" : "512"
  execution_role_arn       = aws_iam_role.cert_cutover_execution[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    merge({
      name      = "web"
      image     = local.ecs_alb_image
      essential = true
      #checkov:skip=CKV_AWS_336: The public nginx image writes its pid/cache under / and cannot run with a read-only root filesystem; acceptable for the throwaway cert health target.
      portMappings = [
        {
          containerPort = local.ecs_alb_container_port
          hostPort      = local.ecs_alb_container_port
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.cert_cutover[0].name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "web"
        }
      }
      }, local.ecs_alb_honua ? {
      environment = [for name, value in local.ecs_alb_honua_environment : { name = name, value = value }]
      secrets     = [for name, arn in local.ecs_alb_honua_secrets : { name = name, valueFrom = arn } if arn != ""]
    } : {})
  ])

  tags = local.tags
}

# ---------------------------------------------------------------------------
# One ECS service attached to BOTH target groups (dual load_balancer blocks) so
# both always carry the same healthy tasks — the weight-shift is pure ALB.
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "cert_cutover" {
  count           = local.ecs_alb_enabled ? 1 : 0
  name            = "${local.ecs_alb_name}-service"
  cluster         = aws_ecs_cluster.cert_cutover[0].id
  task_definition = aws_ecs_task_definition.cert_cutover[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets = module.honua.private_subnet_ids
    # Serving mode adds the module's Lambda security group, which the cert
    # PostGIS and Redis security groups already admit.
    security_groups  = local.ecs_alb_honua ? [aws_security_group.cert_cutover_ecs[0].id, module.honua.lambda_security_group_id] : [aws_security_group.cert_cutover_ecs[0].id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.cert_cutover_stable[0].arn
    container_name   = "web"
    container_port   = local.ecs_alb_container_port
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.cert_cutover_canary[0].arn
    container_name   = "web"
    container_port   = local.ecs_alb_container_port
  }

  depends_on = [aws_lb_listener.cert_cutover]

  tags = local.tags
}


# The weighted-cutover rule the certification cell (and the production
# AwsEcsAlbDeployBackend) actually modifies. AWS forbids ModifyRule on a
# listener's DEFAULT rule (OperationNotPermitted), so the weighted forward
# action must live on a dedicated non-default rule — exactly how a real
# canary deployment is wired. The default action above stays a stable-only
# fallback that never changes.
resource "aws_lb_listener_rule" "cert_cutover" {
  count = var.enable_ecs_alb_cert ? 1 : 0

  listener_arn = aws_lb_listener.cert_cutover[0].arn
  priority     = 1

  action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.cert_cutover_stable[0].arn
        weight = 100
      }

      target_group {
        arn    = aws_lb_target_group.cert_cutover_canary[0].arn
        weight = 0
      }
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  lifecycle {
    # The certification run shifts these weights mid-flight and restores them in
    # its finally block; a later apply must not fight an in-flight run.
    ignore_changes = [action]
  }

  tags = local.tags
}
