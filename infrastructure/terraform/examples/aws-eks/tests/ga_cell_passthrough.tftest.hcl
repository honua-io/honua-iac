# The aws-eks root is the release harness's EKS cell entrypoint. These runs pass
# the inputs the harness passes to the ECS/Lambda roots, by the same names, and
# assert they reach the module and come back out as the handoff outputs the
# chart and harness read. Offline: every provider is mocked.

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

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:role/honua-release-cicd"
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

# The harness's base inputs (e2e/targets/aws_eks.py _tf_vars).
variables {
  region                                   = "us-east-1"
  name_prefix                              = "honuaeksr123456"
  environment                              = "it"
  cluster_endpoint_public_access           = true
  cluster_endpoint_public_access_cidrs     = ["203.0.113.10/32"]
  enable_cluster_creator_admin_permissions = true
  cluster_secret_encryption_enabled        = false

  # The harness passes it on every cell (HONUA_AWS_AUDIT_CHAIN_KEY_SECRET_ARN);
  # without it a real plan only warns, but a test run counts the check as failed.
  audit_chain_key_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-release/cert/audit-chain-key-RLtpME"
}

run "pre_ga_harness_inputs_still_plan" {
  command = plan

  assert {
    condition     = output.workload_identity_mode == "pod_identity" && !output.redis_enabled && output.database_managed
    error_message = "The pre-GA harness inputs alone must plan with Pod Identity, a managed database and Redis off."
  }
}

run "ga_cell_redis_on" {
  command = plan

  variables {
    honua_admin_password                      = "Honua-Cert-Admin-Aa1!xxxxxxxxxxxxxxxx"
    enable_redis                              = true
    operation_key_ring_certificate_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-release/cert/operation-key-ring-zDn618"
    enable_postgis                            = true
    db_publicly_accessible                    = true
    db_additional_ingress_cidrs               = ["203.0.113.10/32"]
    rds_deletion_protection                   = false
    kubernetes_namespace                      = "honua-cert"
    gp_job_image                              = "ghcr.io/honua-io/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    operations_policy_rules = [
      { operation_id = "*", role = "scoped-admin-key", decision = "Allow", reason = "Release cell: scoped admin keys run typed operations" },
      { operation_id = "*", role = "admin", decision = "Allow", reason = "Release cell: bootstrap and full admins run typed operations" },
    ]
    cors_allowed_origins = ["http://127.0.0.1:18099"]
    domain_name          = "run-aws-eks-redis-on.cert.demo.example.com"
    route53_zone_id      = "Z0123456789ABCDEFGHIJ"
  }

  assert {
    condition     = output.redis_enabled && output.postgis_enabled && output.operation_key_ring_certificate_secret_arn == "arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-release/cert/operation-key-ring-zDn618"
    error_message = "Redis, PostGIS and the key ring must reach the module."
  }

  assert {
    condition = (
      output.honua_server_environment["Operations__SecretChannel__KeyRingCertificatePkcs12"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-release/cert/operation-key-ring-zDn618" &&
      output.honua_server_environment["AuditLog__ChainVerification__Key"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-release/cert/audit-chain-key-RLtpME" &&
      output.honua_server_environment["Operations__Policy__Rules__1__Role"] == "admin" &&
      output.honua_server_environment["ControlPlane__Kubernetes__DefaultNamespace"] == "honua-cert" &&
      output.honua_server_environment["ControlPlane__Kubernetes__DefaultImage"] == "ghcr.io/honua-io/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    )
    error_message = "The server environment must carry the cell's references, rules and GP defaults."
  }

  assert {
    condition = (
      output.chart_config_env["Cors__AllowedOrigins__0"] == "http://127.0.0.1:18099" &&
      output.chart_config_env["Operations__Policy__Rules__0__Role"] == "scoped-admin-key" &&
      output.chart_config_env["ControlPlane__Kubernetes__DefaultServiceAccount"] == "honua-gp-job" &&
      output.chart_config_env["Operations__SecretChannel__KeyRingCertificatePkcs12"] == "aws:secretsmanager:arn:aws:secretsmanager:us-east-1:123456789012:secret:honua-release/cert/operation-key-ring-zDn618" &&
      !contains(keys(output.chart_config_env), "ConnectionStrings__DefaultConnection") &&
      !contains(keys(output.chart_config_env), "HONUA_ADMIN_PASSWORD") &&
      !contains(keys(output.chart_config_env), "Security__ConnectionEncryption__MasterKey") &&
      !contains(keys(output.chart_config_env), "ConnectionStrings__redis")
    )
    error_message = "chart_config_env must carry the non-credential settings and none of the Secret's credentials."
  }

  assert {
    condition     = output.kubernetes_namespace == "honua-cert" && output.gp_job_namespace == "honua-cert" && output.gp_job_service_account_name == "honua-gp-job"
    error_message = "The GP job namespace defaults to the release namespace."
  }

  assert {
    condition     = output.domain_name == "run-aws-eks-redis-on.cert.demo.example.com" && !output.domain_record_managed && length(output.ingress_service_annotations) == 3
    error_message = "The first apply issues the certificate and hands the chart its TLS annotations."
  }
}

run "ga_cell_redis_off_second_apply_with_load_balancer" {
  command = plan

  variables {
    enable_redis                   = false
    domain_name                    = "run-aws-eks-redis-off.cert.demo.example.com"
    route53_zone_id                = "Z0123456789ABCDEFGHIJ"
    ingress_load_balancer_hostname = "a1b2c3-123456789.us-east-1.elb.amazonaws.com"
  }

  assert {
    condition     = !output.redis_enabled && output.redis_connection_secret_arn == "" && !contains(keys(output.honua_server_environment), "ConnectionStrings__redis")
    error_message = "A Redis-off cell carries no Redis."
  }

  assert {
    condition     = output.domain_record_managed && output.honua_url == "https://run-aws-eks-redis-off.cert.demo.example.com"
    error_message = "The second apply points the cell domain at the chart's load balancer."
  }
}
