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
  ecs_alb_image = "public.ecr.aws/nginx/nginx:stable-alpine"
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
    description = "HTTP from within the VPC (internal ALB; cert drives control-plane APIs, not this data path)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [module.honua.vpc_cidr_block]
  }

  egress {
    description     = "ALB to ECS targets on the container port"
    from_port       = 80
    to_port         = 80
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

  tags = local.tags
}

# Separate ingress rule (avoids an SG-to-SG dependency cycle with the ALB SG).
resource "aws_security_group_rule" "cert_cutover_ecs_from_alb" {
  count                    = local.ecs_alb_enabled ? 1 : 0
  type                     = "ingress"
  description              = "ALB to task on container port 80"
  from_port                = 80
  to_port                  = 80
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
  count                      = local.ecs_alb_enabled ? 1 : 0
  name                       = "${local.ecs_alb_name}-alb"
  load_balancer_type         = "application"
  internal                   = true
  security_groups            = [aws_security_group.cert_cutover_alb[0].id]
  subnets                    = module.honua.private_subnet_ids
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
    path                = "/"
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
    path                = "/"
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
  count                    = local.ecs_alb_enabled ? 1 : 0
  family                   = "${local.ecs_alb_name}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.cert_cutover_execution[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "web"
      image     = local.ecs_alb_image
      essential = true
      #checkov:skip=CKV_AWS_336: The public nginx image writes its pid/cache under / and cannot run with a read-only root filesystem; acceptable for the throwaway cert health target.
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
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
    }
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
    subnets          = module.honua.private_subnet_ids
    security_groups  = [aws_security_group.cert_cutover_ecs[0].id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.cert_cutover_stable[0].arn
    container_name   = "web"
    container_port   = 80
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.cert_cutover_canary[0].arn
    container_name   = "web"
    container_port   = 80
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
