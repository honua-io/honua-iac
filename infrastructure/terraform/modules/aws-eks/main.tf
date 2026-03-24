data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.name_prefix}-${var.environment}"
  tags = merge({
    Project     = "honua-server"
    Environment = var.environment
    ManagedBy   = "terraform"
  }, var.tags)
  use_existing_vpc = var.existing_vpc_id != ""
  vpc_id           = local.use_existing_vpc ? var.existing_vpc_id : module.vpc[0].vpc_id
  vpc_cidr_block   = local.use_existing_vpc ? var.existing_vpc_cidr : module.vpc[0].vpc_cidr_block
  public_subnets   = local.use_existing_vpc ? var.existing_public_subnet_ids : module.vpc[0].public_subnets
  private_subnets  = local.use_existing_vpc ? var.existing_private_subnet_ids : module.vpc[0].private_subnets
}

check "public_endpoint_cidrs_required" {
  assert {
    condition     = (!var.cluster_endpoint_public_access) || length(var.cluster_endpoint_public_access_cidrs) > 0
    error_message = "cluster_endpoint_public_access_cidrs must be set when cluster_endpoint_public_access is true."
  }
}

check "existing_vpc_inputs" {
  assert {
    condition = (
      (var.existing_vpc_id == "" && var.existing_vpc_cidr == "" && length(var.existing_public_subnet_ids) == 0 && length(var.existing_private_subnet_ids) == 0) ||
      (var.existing_vpc_id != "" && var.existing_vpc_cidr != "" && length(var.existing_public_subnet_ids) > 0 && length(var.existing_private_subnet_ids) > 0)
    )
    error_message = "existing_vpc_id, existing_vpc_cidr, existing_public_subnet_ids, and existing_private_subnet_ids must be set together."
  }
}

check "managed_node_group_bounds" {
  assert {
    condition = (
      var.node_max_size >= var.node_min_size &&
      var.node_desired_size >= var.node_min_size &&
      var.node_desired_size <= var.node_max_size
    )
    error_message = "node_min_size, node_desired_size, and node_max_size must satisfy node_min_size <= node_desired_size <= node_max_size."
  }
}

#checkov:skip=CKV_TF_1: Registry modules are version-pinned.
module "vpc" {
  count = local.use_existing_vpc ? 0 : 1
  #checkov:skip=CKV_TF_1: Registry modules are version-pinned.
  #checkov:skip=CKV2_AWS_12: Default SG is managed via module inputs.
  source = "../vendor/aws-vpc"

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
  description             = "EKS secret encryption key for ${local.name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                              = "${local.name}-eks"
  cluster_version                           = var.cluster_version
  iam_role_name                             = "${local.name}-eks-cluster"
  iam_role_use_name_prefix                  = false
  cluster_encryption_policy_name            = "${local.name}-eks-cluster-encryption"
  cluster_encryption_policy_use_name_prefix = false

  cluster_endpoint_public_access           = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  cluster_endpoint_private_access          = true
  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions

  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

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

  vpc_id                   = local.vpc_id
  subnet_ids               = local.private_subnets
  control_plane_subnet_ids = local.private_subnets

  eks_managed_node_groups = {
    default = {
      name                     = "default"
      iam_role_name            = "${local.name}-eks-node"
      iam_role_use_name_prefix = false
      instance_types           = var.node_instance_types
      ami_type                 = "AL2023_x86_64_STANDARD"
      disk_size                = 50
      min_size                 = var.node_min_size
      max_size                 = var.node_max_size
      desired_size             = var.node_desired_size
      subnet_ids               = local.private_subnets
    }
  }

  tags = local.tags
}
