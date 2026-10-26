data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.name_prefix}-${var.environment}"

  # A module-managed CMK is minted only when secret encryption is on AND the caller did not
  # hand us a key to reuse. Ephemeral parity/validation clusters turn encryption off entirely
  # (honua-release#127): every destroyed cluster's CMK sits in PendingDeletion for the 7 days
  # AWS refuses to shorten, billing the whole time, and nothing in the parity suite asserts
  # anything about envelope-encrypted secrets. A caller that DOES need the encryption path
  # exercised without a key per cell passes a long-lived key ARN instead.
  create_secret_encryption_key = var.cluster_secret_encryption_enabled && var.cluster_secret_encryption_key_arn == ""

  secret_encryption_key_arn = local.create_secret_encryption_key ? one(aws_kms_key.eks[*].arn) : var.cluster_secret_encryption_key_arn

  # The pinned EKS module enables encryption_config only when this object is non-empty. A
  # `cond ? { provider_key_arn, resources } : {}` conditional cannot unify those two object
  # types and fails at plan (honua-iac#215), so filter the attributes instead: the disabled
  # shape is still an empty object.
  cluster_encryption_config = {
    for attribute, value in {
      provider_key_arn = local.secret_encryption_key_arn
      resources        = ["secrets"]
    } : attribute => value if var.cluster_secret_encryption_enabled
  }

  # IAM names the cluster owns all start with local.name. The release account's
  # cell guardrail (honua-release-cicd: DenyIamOutsideCellNamespace) refuses any
  # role outside the run-scoped name prefix, and the upstream module's default
  # node-group role name ("<node group key>-eks-node-group-") is not under it:
  # e2e-cloud-aws run 38057015781 died on iam:CreateRole for
  # role/default-eks-node-group-2026101014522336640000000a.
  node_group_role_name = "${local.name}-eks-node"

  # Workload identity. Pod Identity binds IAM roles to service accounts through
  # the EKS API and needs no account-level IAM OIDC provider; IRSA needs one per
  # cluster, which the same guardrail denies outright (iam:*OpenIDConnectProvider*,
  # the other half of run 38057015781's failure). IRSA stays available for
  # operators who standardise on it.
  irsa_enabled         = var.workload_identity_mode == "irsa"
  pod_identity_enabled = var.workload_identity_mode == "pod_identity"

  cluster_addons = merge({
    coredns = {
      addon_version = lookup(var.cluster_addon_versions, "coredns", null)
    }
    kube-proxy = {
      addon_version = lookup(var.cluster_addon_versions, "kube-proxy", null)
    }
    vpc-cni = {
      addon_version = lookup(var.cluster_addon_versions, "vpc-cni", null)
    }
    }, local.pod_identity_enabled ? {
    eks-pod-identity-agent = {
      addon_version = lookup(var.cluster_addon_versions, "eks-pod-identity-agent", null)
    }
  } : {})

  tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.tags)
}

check "public_endpoint_cidrs_required" {
  assert {
    condition     = (!var.cluster_endpoint_public_access) || length(var.cluster_endpoint_public_access_cidrs) > 0
    error_message = "cluster_endpoint_public_access_cidrs must be set when cluster_endpoint_public_access is true."
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name}-eks-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, length(var.private_subnet_cidrs))
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_support   = true
  enable_dns_hostnames = true

  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.tags
}

#checkov:skip=CKV2_AWS_64: The default AWS KMS key policy is sufficient for this module's EKS secret encryption key.
resource "aws_kms_key" "eks" {
  #checkov:skip=CKV2_AWS_64: The default AWS KMS key policy is sufficient for this module's EKS secret encryption key.
  count = local.create_secret_encryption_key ? 1 : 0

  description             = "EKS secret encryption key for ${local.name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${local.name}-eks"
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  cluster_endpoint_private_access          = true
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions

  # The key is ours (or the caller's); never let the upstream module mint a second one.
  create_kms_key            = false
  cluster_encryption_config = local.cluster_encryption_config

  cluster_addons = local.cluster_addons

  # No account-level OIDC provider unless the operator chose IRSA (see locals).
  enable_irsa = local.irsa_enabled

  # Cluster role boundary. Empty keeps the upstream default (no boundary).
  iam_role_permissions_boundary = var.infrastructure_permissions_boundary_arn != "" ? var.infrastructure_permissions_boundary_arn : null

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      name           = "default"
      instance_types = var.node_instance_types
      ami_type       = upper(var.node_cpu_architecture) == "ARM64" ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"
      disk_size      = 50
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
      subnet_ids     = module.vpc.private_subnets

      iam_role_name            = local.node_group_role_name
      iam_role_use_name_prefix = false

      iam_role_permissions_boundary = var.infrastructure_permissions_boundary_arn != "" ? var.infrastructure_permissions_boundary_arn : null
    }
  }

  tags = local.tags
}
