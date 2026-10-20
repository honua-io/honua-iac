provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_eks_cluster" "selected" {
  name = var.cluster_name
}

data "aws_route53_zone" "selected" {
  count   = var.route53_zone_id == "" ? 0 : 1
  zone_id = var.route53_zone_id
}

# The existing cluster must be reachable from this exact-plan runner. The exec
# credential is fetched when the provider connects, rather than serialized in
# Terraform state or passed as a Terraform variable.
provider "kubernetes" {
  host                   = data.aws_eks_cluster.selected.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.selected.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

data "external" "cluster_ca" {
  program = ["python3", "${path.module}/scripts/ca-der-sha256.py"]
  query = {
    pem_base64 = data.aws_eks_cluster.selected.certificate_authority[0].data
  }
}

data "external" "pod_identity_agent" {
  program = ["python3", "${path.module}/scripts/read-eks-addon-status.py"]
  query = {
    region       = var.region
    cluster_name = var.cluster_name
    addon_name   = "eks-pod-identity-agent"
  }
}

data "external" "server_association" {
  program = ["python3", "${path.module}/scripts/read-pod-identity-association.py"]
  query = {
    region         = var.region
    cluster_name   = var.cluster_name
    association_id = var.server_pod_identity_association_id
  }
}

data "external" "gp_job_association" {
  program = ["python3", "${path.module}/scripts/read-pod-identity-association.py"]
  query = {
    region         = var.region
    cluster_name   = var.cluster_name
    association_id = var.gp_job_pod_identity_association_id
  }
}

locals {
  labels = {
    "app.kubernetes.io/name"       = "honua"
    "app.kubernetes.io/instance"   = var.target_id
    "app.kubernetes.io/managed-by" = "terraform"
  }
  selector = {
    "app.kubernetes.io/instance" = var.target_id
    "app.kubernetes.io/name"     = "honua"
  }
  server_digest = element(split("@", var.image_reference), 1)
  gp_job_digest = element(split("@", var.gp_job_image_reference), 1)
  service_name  = "${var.deployment_name}-public"
  public_url    = "https://${var.public_hostname}"
  lb_hostname   = kubernetes_service_v1.public.status[0].load_balancer[0].ingress[0].hostname
  required_secret_arns = [
    var.db_connection_secret_arn,
    var.admin_password_secret_arn,
    var.master_key_secret_arn,
  ]
  optional_secret_arns = [
    var.redis_connection_secret_arn,
    var.operation_key_ring_certificate_secret_arn,
    var.audit_chain_key_secret_arn,
  ]
  secret_environment = merge({
    ConnectionStrings__DefaultConnection      = "aws:secretsmanager:${var.db_connection_secret_arn}"
    HONUA_ADMIN_PASSWORD                      = "aws:secretsmanager:${var.admin_password_secret_arn}"
    Security__ConnectionEncryption__MasterKey = "aws:secretsmanager:${var.master_key_secret_arn}"
    }, var.redis_connection_secret_arn == "" ? {} : {
    ConnectionStrings__redis = "aws:secretsmanager:${var.redis_connection_secret_arn}"
    }, var.operation_key_ring_certificate_secret_arn == "" ? {} : {
    Operations__SecretChannel__KeyRingCertificatePkcs12 = "aws:secretsmanager:${var.operation_key_ring_certificate_secret_arn}"
    }, var.audit_chain_key_secret_arn == "" ? {} : {
    AuditLog__ChainVerification__Key = "aws:secretsmanager:${var.audit_chain_key_secret_arn}"
  })
  controller_annotations = var.load_balancer_controller == "aws-load-balancer-controller" ? {
    "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
    "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
    } : {
    "service.beta.kubernetes.io/aws-load-balancer-type"             = "nlb"
    "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "http"
  }
}

resource "kubernetes_namespace_v1" "honua" {
  metadata {
    name   = var.namespace
    labels = local.labels
  }
}

resource "kubernetes_service_account_v1" "server" {
  metadata {
    name      = var.server_service_account_name
    namespace = kubernetes_namespace_v1.honua.metadata[0].name
    labels    = local.labels
  }
}

resource "kubernetes_service_account_v1" "gp_job" {
  metadata {
    name      = var.gp_job_service_account_name
    namespace = kubernetes_namespace_v1.honua.metadata[0].name
    labels    = local.labels
  }
}

# The server's Kubernetes Job backend needs namespace-scoped Job access. The GP
# runner has its own service account and IAM role, never the node role.
resource "kubernetes_role_v1" "server_jobs" {
  metadata {
    name      = "${var.deployment_name}-jobs"
    namespace = kubernetes_namespace_v1.honua.metadata[0].name
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "get", "list", "watch", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "server_jobs" {
  metadata {
    name      = "${var.deployment_name}-jobs"
    namespace = kubernetes_namespace_v1.honua.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.server_jobs.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.server.metadata[0].name
    namespace = kubernetes_namespace_v1.honua.metadata[0].name
  }
}

resource "kubernetes_deployment_v1" "honua" {
  metadata {
    name      = var.deployment_name
    namespace = kubernetes_namespace_v1.honua.metadata[0].name
    labels    = local.labels
  }
  spec {
    replicas = var.replicas
    selector {
      match_labels = local.selector
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        service_account_name = kubernetes_service_account_v1.server.metadata[0].name
        container {
          name              = var.container_name
          image             = var.image_reference
          image_pull_policy = "IfNotPresent"
          port {
            name           = "http"
            container_port = 8080
          }
          dynamic "env" {
            for_each = merge(local.secret_environment, {
              ASPNETCORE_URLS                                 = "http://0.0.0.0:8080"
              Public__BaseUrl                                 = local.public_url
              ControlPlane__Kubernetes__DefaultNamespace      = var.namespace
              ControlPlane__Kubernetes__DefaultServiceAccount = var.gp_job_service_account_name
              ControlPlane__Kubernetes__DefaultImage          = var.gp_job_image_reference
            })
            content {
              name  = env.key
              value = env.value
            }
          }
          readiness_probe {
            http_get {
              path = "/healthz/ready"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 30
            period_seconds        = 20
          }
          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "2", memory = "2Gi" }
          }
        }
      }
    }
  }
  lifecycle {
    precondition {
      condition = (local.server_digest == var.artifact_capabilities.server_image_digest &&
        local.gp_job_digest == var.artifact_capabilities.gp_job_image_digest &&
      contains(var.artifact_capabilities.supported_workload_identities, var.workload_identity_mode))
      error_message = "The reviewed artifact capabilities must match both image digests and support the selected workload identity mode."
    }
    precondition {
      condition = (var.server_role_arn != var.gp_job_role_arn &&
        can(regex("^arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/", var.server_role_arn)) &&
      can(regex("^arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/", var.gp_job_role_arn)))
      error_message = "Server and GP Job roles must be distinct IAM roles in the selected cluster account."
    }
    precondition {
      condition = (data.external.pod_identity_agent.result.status == "ACTIVE" &&
        data.external.server_association.result.namespace == var.namespace &&
        data.external.server_association.result.service_account == var.server_service_account_name &&
        data.external.server_association.result.role_arn == var.server_role_arn &&
        data.external.gp_job_association.result.namespace == var.namespace &&
        data.external.gp_job_association.result.service_account == var.gp_job_service_account_name &&
      data.external.gp_job_association.result.role_arn == var.gp_job_role_arn)
      error_message = "The Pod Identity agent must be ACTIVE and both existing associations must bind the selected namespace, service accounts and distinct workload roles."
    }
    precondition {
      condition     = can(regex("^arn:${data.aws_partition.current.partition}:acm:${var.region}:${data.aws_caller_identity.current.account_id}:certificate/", var.certificate_arn))
      error_message = "The public TLS certificate must belong to the selected cluster account and region."
    }
    precondition {
      condition = alltrue([for arn in concat(local.required_secret_arns, [for arn in local.optional_secret_arns : arn if arn != ""]) :
        can(regex("^arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:[A-Za-z0-9/_+=.@-]+$", arn))
      ])
      error_message = "Every runtime secret reference must be a Secrets Manager ARN in the selected cluster account and region."
    }
  }
}

resource "kubernetes_service_v1" "public" {
  metadata {
    name      = local.service_name
    namespace = kubernetes_namespace_v1.honua.metadata[0].name
    labels    = local.labels
    annotations = merge(local.controller_annotations, {
      "service.beta.kubernetes.io/aws-load-balancer-scheme"    = "internet-facing"
      "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"  = var.certificate_arn
      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports" = "443"
    })
  }
  spec {
    selector = local.selector
    type     = "LoadBalancer"
    port {
      name        = "https"
      port        = 443
      target_port = 8080
      protocol    = "TCP"
    }
  }
  wait_for_load_balancer = true
  depends_on             = [kubernetes_deployment_v1.honua]
}

resource "aws_route53_record" "public" {
  count   = var.route53_zone_id == "" ? 0 : 1
  zone_id = var.route53_zone_id
  name    = var.public_hostname
  type    = "CNAME"
  ttl     = 60
  records = [local.lb_hostname]

  lifecycle {
    precondition {
      condition = (!data.aws_route53_zone.selected[0].private_zone &&
        trimsuffix(var.public_hostname, ".") != trimsuffix(data.aws_route53_zone.selected[0].name, ".") &&
      endswith(var.public_hostname, ".${trimsuffix(data.aws_route53_zone.selected[0].name, ".")}"))
      error_message = "public_hostname must be a non-apex name inside a public Route53 zone to manage its CNAME."
    }
  }
}
