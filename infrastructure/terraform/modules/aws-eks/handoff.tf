# What the Helm chart and the release harness consume from this module.
#
# honua_server_environment is the server's environment as name => value, ready
# for the chart's env values. Secret values never appear: each one is an
# aws:secretsmanager:<arn> reference the server resolves at startup with its
# workload role (the same reference contract the aws-serverless Lambda and GP
# Batch containers use). Only ARNs and plain settings are rendered, so the map
# is not sensitive.

locals {
  # Operation policy rules (honua-server Operations:Policy:Rules). Identical
  # rendering to modules/aws-ecs and modules/aws-serverless: first-match-wins in
  # list order, unset optional fields render nothing.
  operations_policy_environment = merge({}, [
    for index, rule in var.operations_policy_rules : {
      for field, value in {
        OperationId  = rule.operation_id
        Role         = rule.role
        Tier         = rule.tier
        Decision     = rule.decision
        Reason       = rule.reason
        ApprovalLane = rule.approval_lane
      } : "Operations__Policy__Rules__${index}__${field}" => value if value != null
    }
  ]...)

  # GP on Kubernetes: the server's Kubernetes Job backend defaults
  # (ControlPlane:Kubernetes:*). The chart owns the Job RBAC and the job
  # service account object; this module owns the job service account's IAM role.
  control_plane_kubernetes_environment = merge({
    ControlPlane__Kubernetes__DefaultNamespace      = local.gp_job_namespace
    ControlPlane__Kubernetes__DefaultServiceAccount = var.gp_job_service_account_name
    }, var.gp_job_image != "" ? {
    ControlPlane__Kubernetes__DefaultImage = var.gp_job_image
  } : {})

  secret_reference_environment = merge(
    {
      ConnectionStrings__DefaultConnection      = "aws:secretsmanager:${aws_secretsmanager_secret.db_connection.arn}"
      HONUA_ADMIN_PASSWORD                      = "aws:secretsmanager:${aws_secretsmanager_secret.admin_password.arn}"
      Security__ConnectionEncryption__MasterKey = "aws:secretsmanager:${aws_secretsmanager_secret.master_key.arn}"
    },
    var.redis_enabled ? {
      ConnectionStrings__redis = "aws:secretsmanager:${aws_secretsmanager_secret.redis_connection[0].arn}"
    } : {},
    var.redis_enabled && var.operation_key_ring_certificate_secret_arn != "" ? {
      Operations__SecretChannel__KeyRingCertificatePkcs12 = "aws:secretsmanager:${var.operation_key_ring_certificate_secret_arn}"
    } : {},
    var.audit_chain_key_secret_arn != "" ? {
      AuditLog__ChainVerification__Key = "aws:secretsmanager:${var.audit_chain_key_secret_arn}"
    } : {},
  )

  # Browser origins, same rendering as modules/aws-ecs.
  cors_environment = { for index, origin in var.cors_allowed_origins : "Cors__AllowedOrigins__${index}" => origin }

  # Operator-owned secrets (never generated here) travel by reference in both
  # maps; the release harness puts the module-generated credentials into its
  # own Kubernetes Secret instead.
  operator_secret_reference_environment = {
    for name, value in local.secret_reference_environment : name => value
    if contains(["Operations__SecretChannel__KeyRingCertificatePkcs12", "AuditLog__ChainVerification__Key"], name)
  }

  # Public:BaseUrl. honua-server builds absolute links (publication URLs,
  # OGC/STAC self links, admin OIDC redirect URIs) only from Public:BaseUrl /
  # PUBLIC_BASE_URL, never from the request Host; the chart defaults
  # config.env.Public__BaseUrl to "". With a managed custom domain (domain_name
  # + route53_zone_id, TLS on the chart's Service) it is https://<domain_name>;
  # public_base_url overrides it (for example a customer ingress or CDN host).
  # Any customer FQDN works; nothing assumes a DNS suffix.
  public_base_url = trimsuffix(var.public_base_url, "/") != "" ? trimsuffix(var.public_base_url, "/") : (
    local.use_managed_cert ? "https://${var.domain_name}" : ""
  )
  public_base_url_environment = local.public_base_url != "" ? { Public__BaseUrl = local.public_base_url } : {}

  # The managed certificate terminates TLS on the chart's Service load balancer
  # and the backend protocol is HTTP (ingress.tf). honua-server then sees an
  # http request and, with SecurityHeaders:HstsHttpsOnly at its default, omits
  # Strict-Transport-Security on the public https:// endpoint (honua-release
  # e2e-cloud-aws run 41038212574, both EKS cells). Same contract as
  # modules/aws-ecs and modules/aws-serverless: emit the header for that
  # trusted hop. A plain-HTTP Service, including one that only sets
  # public_base_url, keeps the server default.
  hsts_environment = local.use_managed_cert ? { SecurityHeaders__HstsHttpsOnly = "false" } : {}

  # chart_config_env: everything the chart's config.env needs EXCEPT the
  # credentials that belong in the chart's Secret (database, admin password,
  # master key, Redis). Safe to render into release values.
  chart_config_env = merge(
    local.operator_secret_reference_environment,
    local.operations_policy_environment,
    local.cors_environment,
    local.control_plane_kubernetes_environment,
    local.public_base_url_environment,
    local.hsts_environment,
    local.db_pool_sizing_environment,
  )

  # honua_server_environment: the complete environment, with the generated
  # credentials as aws:secretsmanager: references too, for a chart install
  # that resolves every secret through the server's workload role.
  honua_server_environment = merge(
    local.secret_reference_environment,
    local.chart_config_env,
  )
}
