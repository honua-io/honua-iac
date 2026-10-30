# GA certification cell contract for the EKS module (rc.3 owner decisions 12/18).
#
# Offline plans against mocked providers covering every new feature on and off:
#   * the release-account IAM guardrail fixes behind e2e-cloud-aws run
#     38057015781 (node-group role outside the cell prefix, IAM OIDC provider);
#   * Pod Identity / IRSA workload roles for the server and GP Job pods;
#   * RDS PostgreSQL + PostGIS bootstrap, ElastiCache Redis, runtime secrets;
#   * operations_policy_rules rendering (same shape as aws-ecs/aws-serverless);
#   * ACM certificate + Route53 record for the chart's load balancer;
#   * the ControlPlane:Kubernetes handoff for GP on Kubernetes.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  mock_data "aws_partition" {
    defaults = {
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      partition          = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_region" {
    defaults = {
      id     = "us-east-1"
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "tls" {}
mock_provider "time" {}
mock_provider "cloudinit" {}
mock_provider "null" {}
mock_provider "random" {}

# Pin the module-owned secret ARNs at plan time so policy and environment
# assertions compare known values.
override_resource {
  target          = aws_secretsmanager_secret.db_connection
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-db-AAAAAA"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.admin_password
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-admin-BBBBBB"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.master_key
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-connection-encryption-CCCCCC"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.redis_connection
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-redis-DDDDDD"
  }
}

variables {
  name_prefix = "honua"
  environment = "test"

  cluster_secret_encryption_enabled = false
  audit_chain_key_secret_arn        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
}

# --- IAM guardrail (run 38057015781) -------------------------------------------

run "node_group_role_is_inside_the_cell_name_prefix" {
  command = plan

  variables {
    name_prefix = "honuaeksn123456"
    environment = "it"
  }

  assert {
    condition     = module.eks.eks_managed_node_groups["default"].iam_role_name == "honuaeksn123456-it-eks-node"
    error_message = "The node-group role must be named under the cell prefix (the guardrail denies role/default-eks-node-group-*)."
  }

  assert {
    condition     = alltrue([for role in aws_iam_role.workload : startswith(role.name, "honuaeksn123456-it-")])
    error_message = "Every workload role must be named under the cell prefix."
  }
}

run "pod_identity_is_the_default_and_creates_no_oidc_provider" {
  command = plan

  assert {
    condition     = module.eks.oidc_provider_arn == null
    error_message = "The default mode must not create an IAM OIDC provider (the guardrail denies iam:*OpenIDConnectProvider*)."
  }

  assert {
    condition     = contains(keys(local.cluster_addons), "eks-pod-identity-agent")
    error_message = "Pod Identity needs the eks-pod-identity-agent add-on."
  }

  assert {
    condition = (
      length(aws_eks_pod_identity_association.workload) == 2 &&
      aws_eks_pod_identity_association.workload["server"].namespace == "honua" &&
      aws_eks_pod_identity_association.workload["server"].service_account == "honua" &&
      aws_eks_pod_identity_association.workload["gp-job"].namespace == "honua" &&
      aws_eks_pod_identity_association.workload["gp-job"].service_account == "honua-gp-job"
    )
    error_message = "The server and GP job service accounts must each be bound to their role."
  }

  assert {
    condition = alltrue([
      for role in aws_iam_role.workload :
      jsondecode(role.assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com" &&
      contains(jsondecode(role.assume_role_policy).Statement[0].Action, "sts:TagSession")
    ])
    error_message = "Workload roles must trust the EKS Pod Identity service."
  }

  assert {
    condition     = length(output.server_service_account_annotations) == 0 && length(output.gp_job_service_account_annotations) == 0
    error_message = "Pod Identity needs no service-account annotations."
  }
}

run "irsa_mode_uses_the_oidc_provider" {
  command = plan

  variables {
    workload_identity_mode = "irsa"
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.workload) == 0 && !contains(keys(local.cluster_addons), "eks-pod-identity-agent")
    error_message = "IRSA mode must not create Pod Identity associations or the agent add-on."
  }

  assert {
    condition     = local.irsa_enabled && output.workload_identity_mode == "irsa"
    error_message = "IRSA mode must enable the EKS module's OIDC provider."
  }
}

run "unknown_workload_identity_mode_is_rejected" {
  command = plan

  variables {
    workload_identity_mode = "static-keys"
  }

  expect_failures = [var.workload_identity_mode]
}

# --- Secrets and data plane ----------------------------------------------------

run "managed_database_by_default_redis_off" {
  command = plan

  assert {
    condition     = length(module.rds) == 1 && output.database_managed
    error_message = "The root must manage an RDS PostgreSQL instance by default."
  }

  assert {
    condition     = length(null_resource.enable_postgis) == 0 && !output.postgis_enabled
    error_message = "PostGIS bootstrap is opt-in."
  }

  assert {
    condition     = length(aws_elasticache_replication_group.redis) == 0 && length(aws_secretsmanager_secret.redis_connection) == 0
    error_message = "Redis is off by default."
  }

  assert {
    condition = (
      output.honua_server_environment["ConnectionStrings__DefaultConnection"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-db-AAAAAA" &&
      output.honua_server_environment["HONUA_ADMIN_PASSWORD"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-admin-BBBBBB" &&
      output.honua_server_environment["Security__ConnectionEncryption__MasterKey"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-connection-encryption-CCCCCC" &&
      output.honua_server_environment["AuditLog__ChainVerification__Key"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
    )
    error_message = "The server environment must carry aws:secretsmanager: references to the runtime secrets."
  }

  assert {
    condition     = !contains(keys(output.honua_server_environment), "ConnectionStrings__redis") && !contains(keys(output.honua_server_environment), "Operations__SecretChannel__KeyRingCertificatePkcs12")
    error_message = "A Redis-off cell must carry neither the Redis connection nor the key ring."
  }

  assert {
    condition = (
      toset(jsondecode(aws_iam_role_policy.workload_secrets["server"].policy).Statement[0].Resource) == toset([
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-db-AAAAAA",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-admin-BBBBBB",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-connection-encryption-CCCCCC",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123",
      ]) &&
      toset(jsondecode(aws_iam_role_policy.workload_secrets["gp-job"].policy).Statement[0].Resource) == toset([
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-db-AAAAAA",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-connection-encryption-CCCCCC",
      ])
    )
    error_message = "The GP job role reads only the worker's secrets (honua-helm#110 scopes the worker environment); it must not read the server admin or audit secrets."
  }

  assert {
    condition     = alltrue([for secret in [aws_secretsmanager_secret.db_connection, aws_secretsmanager_secret.admin_password, aws_secretsmanager_secret.master_key] : secret.kms_key_id == null])
    error_message = "Secrets default to the AWS-managed key so an ephemeral cluster strands no CMK."
  }
}

run "postgis_bootstrap_on_public_cell_database" {
  command = plan

  variables {
    enable_postgis              = true
    db_publicly_accessible      = true
    db_additional_ingress_cidrs = ["203.0.113.10/32"]
    rds_deletion_protection     = false
  }

  assert {
    condition     = length(null_resource.enable_postgis) == 1 && output.postgis_enabled
    error_message = "enable_postgis must run the PostGIS bootstrap against the managed database."
  }

  assert {
    condition     = contains(flatten([for rule in aws_security_group.rds[0].ingress : rule.cidr_blocks]), "203.0.113.10/32")
    error_message = "The runner CIDR must be admitted to PostgreSQL."
  }
}

run "postgis_bootstrap_requires_reachable_database" {
  command = plan

  variables {
    enable_postgis = true
  }

  expect_failures = [null_resource.enable_postgis]
}

run "existing_database_skips_rds" {
  command = plan

  variables {
    existing_db_endpoint          = "postgres.example.internal"
    existing_db_connection_string = "Host=postgres.example.internal;Database=honua;Username=honua;Password=test;SSL Mode=Require"
  }

  assert {
    condition     = length(module.rds) == 0 && length(aws_security_group.rds) == 0 && !output.database_managed
    error_message = "An existing database must not create RDS."
  }
}

run "redis_on_with_key_ring" {
  command = plan

  variables {
    redis_enabled                                     = true
    operation_key_ring_certificate_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    operation_key_ring_certificate_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
  }

  assert {
    condition = (
      length(aws_elasticache_replication_group.redis) == 1 &&
      aws_elasticache_replication_group.redis[0].transit_encryption_enabled &&
      aws_elasticache_replication_group.redis[0].at_rest_encryption_enabled
    )
    error_message = "Redis must be provisioned with TLS in transit and encryption at rest."
  }

  assert {
    condition = (
      output.honua_server_environment["ConnectionStrings__redis"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-redis-DDDDDD" &&
      output.honua_server_environment["Operations__SecretChannel__KeyRingCertificatePkcs12"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    )
    error_message = "A Redis-on cell must reference the Redis connection and the key-ring certificate."
  }

  assert {
    condition = alltrue([
      for policy in aws_iam_role_policy.workload_secrets :
      contains(jsondecode(policy.policy).Statement[0].Resource, "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123") &&
      contains(jsondecode(policy.policy).Statement[0].Resource, "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-test-redis-DDDDDD") &&
      jsondecode(policy.policy).Statement[1].Resource == ["arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"]
    ])
    error_message = "Both workload roles must read the key ring and Redis secrets and decrypt the key-ring CMK."
  }
}

run "gp_job_reads_server_secrets_restores_parity" {
  command = plan

  variables {
    redis_enabled                                     = true
    operation_key_ring_certificate_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    operation_key_ring_certificate_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
    audit_chain_key_secret_kms_key_arn                = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"
    gp_job_reads_server_secrets                       = true
  }

  # honua-release#1059: with a chart before honua-helm#110 (or environmentScope=server)
  # every S10 worker Job imported the server's environment and exited at startup with
  # AccessDeniedException resolving AuditLog:ChainVerification:Key. The opt-in restores
  # the server's secret set for that case.
  assert {
    condition = (
      contains(jsondecode(aws_iam_role_policy.workload_secrets["gp-job"].policy).Statement[0].Resource, "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123") &&
      contains(jsondecode(aws_iam_role_policy.workload_secrets["gp-job"].policy).Statement[1].Resource, "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002") &&
      contains(jsondecode(aws_iam_role_policy.workload_secrets["gp-job"].policy).Statement[1].Condition.StringEquals["kms:EncryptionContext:SecretARN"], "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123")
    )
    error_message = "With gp_job_reads_server_secrets the GP job role must read the audit-chain key secret and decrypt it with its customer-managed key."
  }

  assert {
    condition = (
      toset(jsondecode(aws_iam_role_policy.workload_secrets["gp-job"].policy).Statement[0].Resource) ==
      toset(jsondecode(aws_iam_role_policy.workload_secrets["server"].policy).Statement[0].Resource)
    )
    error_message = "With gp_job_reads_server_secrets the GP job role must read the same secret set as the server."
  }
}

run "gp_job_withholds_the_audit_chain_key_and_its_cmk_by_default" {
  command = plan

  variables {
    redis_enabled                                     = true
    operation_key_ring_certificate_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"
    operation_key_ring_certificate_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000001"
    audit_chain_key_secret_kms_key_arn                = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"
  }

  # honua-helm#110: the scoped worker environment carries no admin password or audit-chain
  # key, so the GP job role reads neither, nor decrypts the audit-chain CMK.
  assert {
    condition = (
      !contains(jsondecode(aws_iam_role_policy.workload_secrets["gp-job"].policy).Statement[0].Resource, "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123") &&
      !contains(jsondecode(aws_iam_role_policy.workload_secrets["gp-job"].policy).Statement[0].Resource, aws_secretsmanager_secret.admin_password.arn) &&
      !contains(jsondecode(aws_iam_role_policy.workload_secrets["gp-job"].policy).Statement[1].Resource, "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002") &&
      contains(jsondecode(aws_iam_role_policy.workload_secrets["gp-job"].policy).Statement[0].Resource, "arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123")
    )
    error_message = "By default the GP job role must not read the admin password or audit-chain key, nor decrypt the audit-chain CMK; it must still read the key ring."
  }
}

run "redis_on_without_key_ring_fails_the_check" {
  command = plan

  variables {
    redis_enabled = true
  }

  expect_failures = [check.redis_requires_operation_key_ring]
}

# --- Operation policy ----------------------------------------------------------

run "operations_policy_rules_render_in_order" {
  command = plan

  variables {
    operations_policy_rules = [
      { operation_id = "service.publish", role = "publisher", decision = "Allow" },
      {
        role          = "operator"
        tier          = "enterprise"
        decision      = "RequireApproval"
        reason        = "Operator changes need a second reviewer."
        approval_lane = "ops-review"
      },
    ]
  }

  assert {
    condition = output.operations_policy_environment == {
      Operations__Policy__Rules__0__OperationId  = "service.publish"
      Operations__Policy__Rules__0__Role         = "publisher"
      Operations__Policy__Rules__0__Decision     = "Allow"
      Operations__Policy__Rules__1__OperationId  = "*"
      Operations__Policy__Rules__1__Role         = "operator"
      Operations__Policy__Rules__1__Tier         = "enterprise"
      Operations__Policy__Rules__1__Decision     = "RequireApproval"
      Operations__Policy__Rules__1__Reason       = "Operator changes need a second reviewer."
      Operations__Policy__Rules__1__ApprovalLane = "ops-review"
    }
    error_message = "Rules must flatten in order, omitting unset fields, with operation_id defaulting to *."
  }

  assert {
    condition     = output.honua_server_environment["Operations__Policy__Rules__1__Decision"] == "RequireApproval"
    error_message = "The rules must reach the server environment."
  }
}

run "no_operations_policy_rules_render_nothing" {
  command = plan

  assert {
    condition     = length(output.operations_policy_environment) == 0 && length([for k in keys(output.honua_server_environment) : k if startswith(k, "Operations__Policy__")]) == 0
    error_message = "No rules must render no Operations__Policy__ entries."
  }
}

run "unknown_policy_decision_is_rejected" {
  command = plan

  variables {
    operations_policy_rules = [{ operation_id = "service.publish", decision = "Permit" }]
  }

  expect_failures = [var.operations_policy_rules]
}

# --- GP on Kubernetes handoff -------------------------------------------------

run "control_plane_kubernetes_defaults" {
  command = plan

  assert {
    condition = output.control_plane_kubernetes_environment == {
      ControlPlane__Kubernetes__DefaultNamespace      = "honua"
      ControlPlane__Kubernetes__DefaultServiceAccount = "honua-gp-job"
    }
    error_message = "Without an image the handoff carries the namespace and service account only."
  }

  assert {
    condition     = length(aws_iam_role_policy.workload_data_bucket) == 0 && output.gp_job_data_bucket_arn == ""
    error_message = "No data bucket grant unless enabled."
  }
}

run "control_plane_kubernetes_custom_namespace_image_and_bucket" {
  command = plan

  variables {
    kubernetes_namespace        = "honua-cert"
    gp_job_namespace            = "honua-gp"
    gp_job_service_account_name = "gp-runner"
    gp_job_image                = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    gp_job_data_bucket_arn      = "arn:aws:s3:::honuaeks-gp-data"
    gp_job_data_bucket_enabled  = true
  }

  assert {
    condition     = output.honua_server_environment["ControlPlane__Kubernetes__DefaultNamespace"] == "honua-gp" && output.honua_server_environment["ControlPlane__Kubernetes__DefaultServiceAccount"] == "gp-runner" && output.honua_server_environment["ControlPlane__Kubernetes__DefaultImage"] == "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    error_message = "The ControlPlane:Kubernetes defaults must follow the inputs."
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.workload["server"].namespace == "honua-cert" &&
      aws_eks_pod_identity_association.workload["gp-job"].namespace == "honua-gp" &&
      aws_eks_pod_identity_association.workload["gp-job"].service_account == "gp-runner"
    )
    error_message = "Role bindings must follow the namespaces and service accounts."
  }

  assert {
    condition = length(aws_iam_role_policy.workload_data_bucket) == 2 && alltrue([
      for policy in aws_iam_role_policy.workload_data_bucket :
      jsondecode(policy.policy).Statement[0].Resource == ["arn:aws:s3:::honuaeks-gp-data/*"]
    ])
    error_message = "Both workload roles must get the GP data bucket."
  }
}

run "data_bucket_flag_requires_an_arn" {
  command = plan

  variables {
    gp_job_data_bucket_enabled = true
  }

  expect_failures = [aws_iam_role_policy.workload_data_bucket]
}

# --- Custom domain -------------------------------------------------------------

run "no_domain_manages_no_certificate" {
  command = plan

  assert {
    condition     = length(aws_acm_certificate.this) == 0 && length(aws_route53_record.service_alias) == 0 && length(output.ingress_service_annotations) == 0 && output.honua_url == ""
    error_message = "Without a domain no certificate, record or TLS annotation is managed."
  }

  assert {
    condition     = !contains(keys(output.chart_config_env), "Public__BaseUrl") && output.public_base_url == null
    error_message = "Without a domain or public_base_url chart_config_env carries no Public__BaseUrl."
  }
}

run "domain_first_apply_issues_certificate_only" {
  command = plan

  variables {
    domain_name     = "cell.cert.demo.example.com"
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = length(aws_acm_certificate.this) == 1 && length(aws_acm_certificate_validation.this) == 1
    error_message = "A domain must get a DNS-validated ACM certificate."
  }

  assert {
    condition     = length(aws_route53_record.service_alias) == 0 && !output.domain_record_managed
    error_message = "No service record before the chart's load balancer exists."
  }

  assert {
    condition     = length(output.ingress_service_annotations) == 3 && output.ingress_service_annotations["service.beta.kubernetes.io/aws-load-balancer-ssl-ports"] == "443"
    error_message = "The chart must receive the TLS Service annotations."
  }

  # honua-server builds absolute links only from Public:BaseUrl; the chart
  # defaults config.env.Public__BaseUrl to "" (honua-io/honua-release#450).
  assert {
    condition     = output.chart_config_env["Public__BaseUrl"] == "https://cell.cert.demo.example.com" && output.honua_server_environment["Public__BaseUrl"] == "https://cell.cert.demo.example.com"
    error_message = "A managed domain must render Public__BaseUrl=https://<domain_name> into chart_config_env and honua_server_environment."
  }
}

run "domain_second_apply_points_at_the_load_balancer" {
  command = plan

  variables {
    domain_name                    = "cell.cert.demo.example.com"
    route53_zone_id                = "Z0123456789ABCDEFGHIJ"
    ingress_load_balancer_hostname = "a1b2c3-123456789.us-east-1.elb.amazonaws.com"
  }

  assert {
    condition = (
      length(aws_route53_record.service_alias) == 1 &&
      aws_route53_record.service_alias[0].name == "cell.cert.demo.example.com" &&
      length(aws_route53_record.service_alias[0].records) == 1 &&
      contains(aws_route53_record.service_alias[0].records, "a1b2c3-123456789.us-east-1.elb.amazonaws.com")
    )
    error_message = "The domain must point at the chart's load balancer."
  }

  assert {
    condition     = output.honua_url == "https://cell.cert.demo.example.com"
    error_message = "honua_url must be the HTTPS custom domain once the record exists."
  }
}

# --- Release harness contract --------------------------------------------------

run "chart_config_env_carries_settings_not_credentials" {
  command = plan

  variables {
    cors_allowed_origins = ["http://127.0.0.1:18099", "https://console.example.com"]
    operations_policy_rules = [
      { operation_id = "*", role = "admin", decision = "Allow" },
    ]
  }

  assert {
    condition = (
      output.chart_config_env["Cors__AllowedOrigins__0"] == "http://127.0.0.1:18099" &&
      output.chart_config_env["Cors__AllowedOrigins__1"] == "https://console.example.com" &&
      output.chart_config_env["Operations__Policy__Rules__0__Role"] == "admin" &&
      output.chart_config_env["ControlPlane__Kubernetes__DefaultNamespace"] == "honua" &&
      output.chart_config_env["AuditLog__ChainVerification__Key"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"
    )
    error_message = "chart_config_env must carry CORS, policy rules, ControlPlane:Kubernetes and operator secret references."
  }

  assert {
    condition = length(setintersection(toset(keys(output.chart_config_env)), toset([
      "ConnectionStrings__DefaultConnection",
      "HONUA_ADMIN_PASSWORD",
      "Security__ConnectionEncryption__MasterKey",
      "ConnectionStrings__redis",
    ]))) == 0
    error_message = "chart_config_env must not carry the credentials that belong in the chart's Secret."
  }

  assert {
    condition     = output.honua_server_environment["Cors__AllowedOrigins__1"] == "https://console.example.com" && contains(keys(output.honua_server_environment), "ConnectionStrings__DefaultConnection")
    error_message = "honua_server_environment is the complete environment, credentials by reference included."
  }

  assert {
    condition     = output.certificate_arn == ""
    error_message = "No certificate without a managed domain."
  }
}

# --- Public base URL on a customer domain (honua-io/honua-release#450, #282) ----

run "customer_domain_renders_public_base_url" {
  command = plan

  variables {
    domain_name     = "maps.city-of-example.gov.au"
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = output.chart_config_env["Public__BaseUrl"] == "https://maps.city-of-example.gov.au" && output.public_base_url == "https://maps.city-of-example.gov.au"
    error_message = "Any customer domain must render Public__BaseUrl=https://<domain_name>."
  }
}

run "explicit_public_base_url_wins" {
  command = plan

  variables {
    domain_name     = "lb.example.org"
    route53_zone_id = "Z0123456789ABCDEFGHIJ"
    public_base_url = "https://maps.example.org/gis/"
  }

  assert {
    condition     = output.chart_config_env["Public__BaseUrl"] == "https://maps.example.org/gis"
    error_message = "public_base_url (for example the customer's own ingress or CDN host) must win over domain_name, trailing slash trimmed."
  }
}

run "public_base_url_without_a_managed_domain" {
  command = plan

  variables {
    public_base_url = "https://gis.example.com"
  }

  assert {
    condition     = output.chart_config_env["Public__BaseUrl"] == "https://gis.example.com" && length(aws_acm_certificate.this) == 0
    error_message = "public_base_url alone renders Public__BaseUrl and manages no certificate."
  }
}

run "bare_host_public_base_url_is_rejected" {
  command = plan

  variables {
    public_base_url = "gis.example.com"
  }

  expect_failures = [var.public_base_url]
}

run "bedrock_off_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.server_bedrock_invoke) == 0 && !contains(keys(output.chart_config_env), "StudioAiProxy__Enabled")
    error_message = "Bedrock stays off and the GP job role receives no invoke grant."
  }
}

run "bedrock_ships_sonnet_4_6" {
  command = plan

  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.server_bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6",
    ]) && aws_iam_role_policy.server_bedrock_invoke[0].role == aws_iam_role.workload["server"].name && aws_iam_role_policy.server_bedrock_invoke[0].role != aws_iam_role.workload["gp-job"].name
    error_message = "The default grant is exactly the shipped Sonnet 4.6 profile and its three member models, on the server role only."
  }

  assert {
    condition     = output.chart_config_env["StudioAiProxy__Disclosure__Approvals__0__Model"] == "us.anthropic.claude-sonnet-4-6"
    error_message = "The disclosure approval names the shipped default model."
  }
}

run "bedrock_opus_5_5" {
  command = plan

  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
    bedrock_ai_model  = "us.anthropic.claude-opus-5-5"
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.server_bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-opus-5-5",
      "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-5-5",
      "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-opus-5-5",
      "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-opus-5-5",
    ])
    error_message = "Opus 5.5 grants exactly its US profile and the three member-region foundation models."
  }
}

run "bedrock_sonnet_5_5" {
  command = plan

  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
    bedrock_ai_model  = "us.anthropic.claude-sonnet-5-5"
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.server_bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-5-5",
    ])
    error_message = "Sonnet 5.5 grants exactly its US profile and the three member-region foundation models."
  }
}

run "bedrock_gpt_6_1_sol" {
  command = plan

  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
    bedrock_ai_model  = "us.openai.gpt-6.1-sol"
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.server_bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.openai.gpt-6.1-sol",
      "arn:aws:bedrock:us-east-1::foundation-model/openai.gpt-6.1-sol",
      "arn:aws:bedrock:us-east-2::foundation-model/openai.gpt-6.1-sol",
      "arn:aws:bedrock:us-west-2::foundation-model/openai.gpt-6.1-sol",
    ]) && output.chart_config_env["StudioAiProxy__Disclosure__Approvals__0__Model"] == "us.openai.gpt-6.1-sol"
    error_message = "GPT-6.1 Sol grants exactly its profile and member models, and the disclosure names that model."
  }
}

run "bedrock_gpt_6_1_terra" {
  command = plan

  variables {
    enable_bedrock_ai = true
    bedrock_ai_region = "us-east-1"
    bedrock_ai_model  = "us.openai.gpt-6.1-terra"
  }

  assert {
    condition = toset(jsondecode(aws_iam_role_policy.server_bedrock_invoke[0].policy).Statement[0].Resource) == toset([
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.openai.gpt-6.1-terra",
      "arn:aws:bedrock:us-east-1::foundation-model/openai.gpt-6.1-terra",
      "arn:aws:bedrock:us-east-2::foundation-model/openai.gpt-6.1-terra",
      "arn:aws:bedrock:us-west-2::foundation-model/openai.gpt-6.1-terra",
    ])
    error_message = "GPT-6.1 Terra grants exactly its profile and member models."
  }
}

run "bedrock_rejects_unpinned_model" {
  command = plan

  variables {
    enable_bedrock_ai = true
    bedrock_ai_model  = "us.openai.*"
  }

  expect_failures = [var.bedrock_ai_model]
}
