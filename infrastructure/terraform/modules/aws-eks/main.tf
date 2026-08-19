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

  cluster_encryption_config = var.cluster_secret_encryption_enabled ? {
    provider_key_arn = local.secret_encryption_key_arn
    resources        = ["secrets"]
  } : {}
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

  cluster_addons = {
    coredns = {
      addon_version = lookup(var.cluster_addon_versions, "coredns", null)
    }
    kube-proxy = {
      addon_version = lookup(var.cluster_addon_versions, "kube-proxy", null)
    }
    vpc-cni = {
      addon_version = lookup(var.cluster_addon_versions, "vpc-cni", null)
    }
  }

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
    }
  }

  tags = local.tags
}
