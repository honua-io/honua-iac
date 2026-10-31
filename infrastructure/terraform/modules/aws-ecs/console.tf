# Console is an opt-in, separately scaled service. The edge authenticates operators;
# the local header filter prevents forwarded access tokens from replacing the
# server-issued, identity-bound bearer used by Console's session BFF.
variable "console" {
  description = "Console deployment and trusted OIDC edge; null disables Console. Images must be immutable digests."
  type = object({
    image                 = string
    oauth2_proxy_image    = string
    header_filter_image   = string
    cookie_secret_arn     = string
    cookie_secret_kms_arn = optional(string, "")
    email_domain          = string
    cpu                   = optional(number, 512)
    memory                = optional(number, 1024)
  })
  default = null
  validation {
    condition = var.console == null ? true : alltrue([
      for image in [var.console.image, var.console.oauth2_proxy_image, var.console.header_filter_image] :
      can(regex("^[^[:space:]@]+@sha256:[0-9a-f]{64}$", image))
    ])
    error_message = "All Console images must be pinned by sha256 digest."
  }
  validation {
    condition = var.console == null ? true : !contains([
      "6612319d53ed9d3fab1a62848b6402d4340f57c227296003614ac88fe48de4f3",
      "68e5b93c4fa7473ce824aeceb3f1e45d3c464e7fec507fb906944c16d5dd3e51",
      "bdd6ddcb297df1aadce7ced075f131e927ef638ad210c3420caa4387f753b965"
    ], try(split("@sha256:", var.console.image)[1], ""))
    error_message = "This Console image predates hosted server-session identity binding; use a qualified newer image."
  }
  validation {
    condition = var.console == null ? true : (
      can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", var.console.cookie_secret_arn)) &&
      can(regex("^[A-Za-z0-9.-]+$", var.console.email_domain)) &&
      (var.console.cookie_secret_kms_arn == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", var.console.cookie_secret_kms_arn)))
    )
    error_message = "Console requires an exact cookie secret ARN, an explicit email domain and optional KMS key ARN."
  }
}

locals {
  console_enabled = var.console != null
  console_paths = chunklist(flatten([
    ["/", "/studio*", "/catalog*", "/operate*"],
    ["/share*", "/auth/*", "/admin/auth/callback", "/oauth2/*"],
    ["/_framework/*", "/_content/*", "/_studio/*", "/js/*"],
    ["/app*", "/favicon*", "/_blazor*", "/maps/*"],
    ["/embed/*", "/environments*", "/approvals*", "/inbox*"],
    ["/map-proxy/*", "/scene-proxy/*", "/api/studio/*", "/api/agent-workspace*"],
    ["/api/processes/*", "/setup/*", "/not-found", "/version.json"],
    ["/fonts/*", "/images/*", "/css/*"]
  ]), 3)
}

resource "terraform_data" "console" {
  count = local.console_enabled ? 1 : 0
  lifecycle {
    precondition {
      condition     = local.use_https && !local.additional_env_sets_public_base_url && can(regex("^https://[A-Za-z0-9.-]+$", local.public_base_url)) && var.generic_oidc != null && var.operator_bearer != null
      error_message = "Console requires HTTPS, public_base_url, generic_oidc and operator_bearer."
    }
    precondition {
      condition     = var.generic_oidc == null ? false : var.generic_oidc.admin_auth_callback_uri == null || var.generic_oidc.admin_auth_callback_uri == "${local.public_base_url}/admin/auth/callback"
      error_message = "The server OIDC callback must use the Console public origin."
    }
    precondition {
      condition     = var.container_port != 4180 && (var.console.cookie_secret_kms_arn == "" ? true : split(":", var.console.cookie_secret_kms_arn)[3] == split(":", var.console.cookie_secret_arn)[3])
      error_message = "Console requires an unused port 4180 and its cookie key in the secret region."
    }
    precondition {
      condition     = var.canary_listener_rule_priority < 10000
      error_message = "The canary listener priority must be below the Console rule range."
    }
  }
}

resource "aws_iam_role_policy" "console_secrets" {
  count = local.console_enabled ? 1 : 0
  name  = "${local.name}-console-secrets"
  role  = aws_iam_role.task_execution.id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [var.console.cookie_secret_arn] }
    ], var.console.cookie_secret_kms_arn == "" ? [] : [
    { Effect = "Allow", Action = ["kms:Decrypt"], Resource = [var.console.cookie_secret_kms_arn], Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${data.aws_region.current.region}.amazonaws.com" } } }
  ]) })
}
resource "aws_lb_target_group" "console" {
  #checkov:skip=CKV_AWS_378: TLS terminates at the ALB; the edge target uses HTTP within the VPC, matching the server target.
  count       = local.console_enabled ? 1 : 0
  name        = substr("${local.name}-console", 0, 32)
  port        = 4180
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "ip"
  health_check { path = "/ping" }
  tags = local.tags
}
resource "aws_lb_listener_rule" "console" {
  count        = local.console_enabled && local.use_https ? length(local.console_paths) : 0
  listener_arn = aws_lb_listener.https[0].arn
  priority     = 10000 + count.index
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.console[0].arn
  }
  condition {
    path_pattern {
      values = local.console_paths[count.index]
    }
  }
  condition {
    host_header {
      values = [trimprefix(local.public_base_url, "https://")]
    }
  }
  depends_on = [terraform_data.console]
}
resource "aws_iam_role" "console" {
  count                = local.console_enabled ? 1 : 0
  name                 = "${local.name}-console-task"
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.tags
}
resource "aws_ecs_task_definition" "console" {
  count                    = local.console_enabled ? 1 : 0
  family                   = "${local.name}-console"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.console.cpu
  memory                   = var.console.memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.console[0].arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = upper(var.task_cpu_architecture)
  }
  container_definitions = jsonencode([
    {
      name = "console", image = var.console.image, essential = true,
      environment = [
        { name = "ASPNETCORE_URLS", value = "http://127.0.0.1:8081" },
        { name = "Studio__EmbedJsStudio", value = "true" },
        { name = "HONUA_SERVER_BASE_URL", value = local.public_base_url },
        { name = "Honua__Console__Auth__Mode", value = "EdgeForwarded" },
        { name = "Honua__Console__Auth__EdgeForwarded__ServerSessionIssuer", value = try(var.generic_oidc.authority, "") }
      ], logConfiguration = local.container_log_configuration
    },
    {
      name             = "header-filter", image = var.console.header_filter_image, essential = true,
      entryPoint       = ["/bin/sh", "-c"],
      command          = ["printf '%s\\n' 'events {}' 'http { server { listen 127.0.0.1:8082; location / { proxy_set_header Host $host; proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-Host $host; proxy_set_header X-Forwarded-Access-Token \"\"; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade; proxy_pass http://127.0.0.1:8081; } } map $http_upgrade $connection_upgrade { default upgrade; \"\" close; } }' > /tmp/nginx.conf; exec nginx -c /tmp/nginx.conf -g 'daemon off;'"],
      logConfiguration = local.container_log_configuration
    },
    {
      name         = "oidc-edge", image = var.console.oauth2_proxy_image, essential = true,
      portMappings = [{ containerPort = 4180, hostPort = 4180, protocol = "tcp" }],
      environment = [
        { name = "OAUTH2_PROXY_PROVIDER", value = "oidc" },
        { name = "OAUTH2_PROXY_OIDC_ISSUER_URL", value = try(var.generic_oidc.authority, "") },
        { name = "OAUTH2_PROXY_CLIENT_ID", value = try(var.generic_oidc.client_id, "") },
        { name = "OAUTH2_PROXY_HTTP_ADDRESS", value = "0.0.0.0:4180" },
        { name = "OAUTH2_PROXY_UPSTREAMS", value = "http://127.0.0.1:8082/" },
        { name = "OAUTH2_PROXY_REDIRECT_URL", value = "${local.public_base_url}/oauth2/callback" },
        { name = "OAUTH2_PROXY_EMAIL_DOMAINS", value = var.console.email_domain },
        { name = "OAUTH2_PROXY_REVERSE_PROXY", value = "true" },
        { name = "OAUTH2_PROXY_PASS_USER_HEADERS", value = "true" },
        { name = "OAUTH2_PROXY_PASS_ACCESS_TOKEN", value = "true" },
        { name = "OAUTH2_PROXY_SKIP_AUTH_STRIP_HEADERS", value = "true" },
        { name = "OAUTH2_PROXY_USER_ID_CLAIM", value = "sub" },
        { name = "OAUTH2_PROXY_INSECURE_OIDC_SKIP_NONCE", value = "false" },
        { name = "OAUTH2_PROXY_COOKIE_SECURE", value = "true" },
        { name = "OAUTH2_PROXY_COOKIE_SAMESITE", value = "lax" }
      ],
      secrets = [
        { name = "OAUTH2_PROXY_CLIENT_SECRET", valueFrom = try(var.generic_oidc.client_secret_arn, "") },
        { name = "OAUTH2_PROXY_COOKIE_SECRET", valueFrom = var.console.cookie_secret_arn }
      ], logConfiguration = local.container_log_configuration
    }
  ])
  depends_on = [terraform_data.console, aws_iam_role_policy.console_secrets]
  tags       = local.tags
}
resource "aws_ecs_service" "console" {
  count           = local.console_enabled ? 1 : 0
  name            = "${local.name}-console"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.console[0].arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = local.private_subnets
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = var.assign_public_ip
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.console[0].arn
    container_name   = "oidc-edge"
    container_port   = 4180
  }
  depends_on = [aws_lb_listener_rule.console]
  tags       = local.tags
}
