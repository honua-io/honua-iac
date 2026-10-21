# Offline provider mocks cover the native Terraform object graph and input
# refusals. Hosted CI runs `terraform test` after provider init.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:us-east-1:123456789012:cluster/honua-it"
      endpoint              = "https://example.eks.amazonaws.com"
      certificate_authority = [{ data = "Y2VydA==" }]
    }
  }
}

mock_provider "kubernetes" {}
mock_provider "external" {
  mock_data "external" {
    defaults = { result = { sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" } }
  }
}

override_data {
  target = data.external.public_certificate
  values = { result = {
    certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    hostname        = "gis.example.com"
  } }
}

override_data {
  target = data.external.pod_identity_agent
  values = { result = {
    status    = "ACTIVE"
    addon_arn = "arn:aws:eks:us-east-1:123456789012:addon/honua-it/eks-pod-identity-agent/synthetic"
  } }
}

override_data {
  target = data.external.server_association
  values = { result = {
    association_id  = "a-serversynthetic"
    association_arn = "arn:aws:eks:us-east-1:123456789012:podidentityassociation/honua-it/a-serversynthetic"
    namespace       = "honua"
    service_account = "honua"
    role_arn        = "arn:aws:iam::123456789012:role/honua-it-server"
  } }
}

override_data {
  target = data.external.gp_job_association
  values = { result = {
    association_id  = "a-gpsynthetic"
    association_arn = "arn:aws:eks:us-east-1:123456789012:podidentityassociation/honua-it/a-gpsynthetic"
    namespace       = "honua"
    service_account = "honua-gp-job"
    role_arn        = "arn:aws:iam::123456789012:role/honua-it-gp-job"
  } }
}

override_data {
  target          = data.external.public_load_balancer
  override_during = plan
  values = { result = {
    arn                      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/honua-it/aaaaaaaaaaaaaaaa"
    dns_name                 = "honua-it.elb.us-east-1.amazonaws.com"
    canonical_hosted_zone_id = "ZELBEXAMPLE"
  } }
}

override_data {
  target = data.external.public_zone[0]
  values = { result = {
    name    = "example.com."
    zone_id = "ZEXAMPLE"
  } }
}

variables {
  region                 = "us-east-1"
  cluster_name           = "honua-it"
  environment            = "it"
  target_id              = "honua-it"
  tenant_id              = "tenant-a"
  image_reference        = "ghcr.io/honua-io/honua-server@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  gp_job_image_reference = "ghcr.io/honua-io/honua-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  artifact_capabilities = {
    server_image_digest           = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    gp_job_image_digest           = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    supported_workload_identities = ["pod_identity", "irsa"]
  }
  server_role_arn                    = "arn:aws:iam::123456789012:role/honua-it-server"
  gp_job_role_arn                    = "arn:aws:iam::123456789012:role/honua-it-gp-job"
  server_pod_identity_association_id = "a-serversynthetic"
  gp_job_pod_identity_association_id = "a-gpsynthetic"
  db_connection_secret_arn           = "arn:aws:secretsmanager:us-east-1:123456789012:secret:db-123"
  admin_password_secret_arn          = "arn:aws:secretsmanager:us-east-1:123456789012:secret:admin-123"
  master_key_secret_arn              = "arn:aws:secretsmanager:us-east-1:123456789012:secret:master-123"
  redis_connection_secret_arn        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:redis-123"
  public_hostname                    = "gis.example.com"
  certificate_arn                    = "arn:aws:acm:us-east-1:123456789012:certificate/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  route53_zone_id                    = "ZEXAMPLE"
  load_balancer_controller           = "legacy-service-controller"
  operations_policy_rules = [
    { operation_id = "service.publish", role = "publisher", decision = "Allow" },
    { decision = "RequireApproval", approval_lane = "ops-review" },
  ]
  cors_allowed_origins = ["https://console.example.com"]
}

run "native_install_projects_configured_resources" {
  command = plan
  assert {
    condition = (output.runtime_binding_contract.backend == "honua-kubernetes-deployment" &&
      output.runtime_binding_contract.resourceIdentity.routeKind == "LoadBalancerService" &&
      output.runtime_binding_contract.resourceIdentity.servicePort == "443" &&
      output.runtime_binding_contract.resourceIdentity.targetPort == "8080" &&
    output.runtime_binding_contract.resourceIdentity.serverRoleArn != output.runtime_binding_contract.resourceIdentity.gpRoleArn)
    error_message = "Native EKS binding must project the Terraform-owned Service route and distinct workload roles."
  }
  assert {
    condition     = output.operator_contract_status == "unqualified" && output.configured_install.image_digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    error_message = "Without immutable exact-plan identity, an installed image must remain unqualified."
  }
  assert {
    condition = (kubernetes_deployment_v1.honua.spec[0].template[0].spec[0].container[0].image == var.image_reference &&
      kubernetes_deployment_v1.honua.spec[0].template[0].spec[0].service_account_name == var.server_service_account_name &&
      kubernetes_deployment_v1.honua.spec[0].template[0].spec[0].container[0].liveness_probe[0].http_get[0].path == "/healthz/live" &&
      kubernetes_secret_v1.gp_runtime_refs.data["ConnectionStrings__redis"] == "aws:secretsmanager:${var.redis_connection_secret_arn}" &&
      !contains(keys(kubernetes_secret_v1.gp_runtime_refs.data), "HONUA_ADMIN_PASSWORD") &&
      kubernetes_service_v1.public.spec[0].type == "LoadBalancer" &&
      kubernetes_service_v1.public.spec[0].port[0].port == 443 &&
      aws_route53_record.public[0].type == "A" &&
    length(aws_route53_record.public) == 1)
    error_message = "Plan must contain the digest-pinned Deployment, selected service account, public TLS Service, and managed DNS record."
  }
  assert {
    condition = (length([for env in kubernetes_deployment_v1.honua.spec[0].template[0].spec[0].container[0].env : env if env.name == "Operations__Policy__Rules__0__Role" && env.value == "publisher"]) == 1 &&
      length([for env in kubernetes_deployment_v1.honua.spec[0].template[0].spec[0].container[0].env : env if env.name == "Operations__Policy__Rules__1__ApprovalLane" && env.value == "ops-review"]) == 1 &&
    length([for env in kubernetes_deployment_v1.honua.spec[0].template[0].spec[0].container[0].env : env if env.name == "Cors__AllowedOrigins__0" && env.value == "https://console.example.com"]) == 1)
    error_message = "Native server must preserve ordered operation-policy and CORS settings."
  }
}

run "external_dns_is_unqualified" {
  command = plan
  variables {
    route53_zone_id = ""
  }
  assert {
    condition     = output.operator_contract_status == "unqualified" && output.configured_install.route_management == "external-unverified"
    error_message = "External DNS without a provider-owned route cannot qualify a public handoff."
  }
}

run "mutable_image_refused" {
  command = plan
  variables {
    image_reference = "ghcr.io/honua-io/honua-server:latest"
  }
  expect_failures = [var.image_reference]
}

run "omitted_public_host_refused" {
  command = plan
  variables {
    public_hostname = ""
  }
  expect_failures = [var.public_hostname]
}

run "unavailable_identity_capability_refused" {
  command = plan
  variables {
    artifact_capabilities = {
      server_image_digest           = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      gp_job_image_digest           = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      supported_workload_identities = ["irsa"]
    }
  }
  expect_failures = [kubernetes_deployment_v1.honua]
}

run "irsa_refused_for_builtin_secret_resolver" {
  command = plan
  variables {
    workload_identity_mode = "irsa"
  }
  expect_failures = [var.workload_identity_mode]
}

run "gp_worker_without_redis_refused" {
  command = plan
  variables {
    redis_connection_secret_arn = ""
  }
  expect_failures = [kubernetes_deployment_v1.honua]
}

run "wrong_pod_association_refused" {
  command = plan
  override_data {
    target = data.external.server_association
    values = { result = {
      association_id  = "a-serversynthetic"
      association_arn = "arn:aws:eks:us-east-1:123456789012:podidentityassociation/honua-it/a-serversynthetic"
      namespace       = "other-tenant"
      service_account = "honua"
      role_arn        = "arn:aws:iam::123456789012:role/honua-it-server"
    } }
  }
  expect_failures = [kubernetes_deployment_v1.honua]
}
