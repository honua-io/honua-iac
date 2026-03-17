# AWS EKS Module

Provisions an Amazon EKS cluster with a managed node group, dedicated VPC, and KMS encryption for Kubernetes secrets.

## Quick start (dev)

```hcl
module "eks" {
  source = "../../modules/aws-eks"

  environment    = "dev"
  cluster_version = "1.30"

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = ["203.0.113.0/24"]
  enable_cluster_creator_admin_permissions = true
}
```

> **Public endpoint access** requires `cluster_endpoint_public_access_cidrs` when enabled. The module validates this at plan time. For private-only clusters, leave `cluster_endpoint_public_access = false` (the default) and access the API through VPN or bastion.

## Production example

```hcl
module "eks" {
  source = "../../modules/aws-eks"

  environment = "prod"
  name_prefix = "honua"

  # Cluster
  cluster_version = "1.30"

  # Networking
  vpc_cidr             = "10.40.0.0/16"
  private_subnet_cidrs = ["10.40.0.0/20", "10.40.16.0/20", "10.40.32.0/20"]
  public_subnet_cidrs  = ["10.40.48.0/24", "10.40.49.0/24", "10.40.50.0/24"]

  # Node group
  node_instance_types = ["m6i.large"]
  node_min_size       = 2
  node_max_size       = 6
  node_desired_size   = 3

  # Access
  cluster_endpoint_public_access           = false
  enable_cluster_creator_admin_permissions = true

  tags = {
    Project     = "honua"
    Environment = "prod"
  }
}
```

## Networking

The module provisions a dedicated VPC with:

- Public subnets tagged for external load balancers (`kubernetes.io/role/elb`)
- Private subnets tagged for internal load balancers (`kubernetes.io/role/internal-elb`)
- Single NAT gateway for outbound traffic from private subnets
- DNS support and DNS hostnames enabled

Override `vpc_cidr`, `public_subnet_cidrs`, and `private_subnet_cidrs` to fit your network plan. The number of availability zones matches the number of private subnets provided.

## Security

- **KMS encryption**: Kubernetes secrets are encrypted at rest with a dedicated KMS key (auto-created, key rotation enabled).
- **Cluster logging**: API server, audit, authenticator, controller manager, and scheduler logs are sent to CloudWatch.
- **Private endpoint**: The API server endpoint is private-only by default. Enable public access with `cluster_endpoint_public_access` and restrict it with `cluster_endpoint_public_access_cidrs`.
- **Default security group**: The default VPC security group is locked down (no ingress, no egress).

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `cluster_version` | `"1.30"` | EKS Kubernetes version. |
| `node_instance_types` | `["t3.medium"]` | Managed node group instance types. Use `m6i.*` or `m7g.*` for production. |
| `node_min_size` | `1` | Minimum node count. |
| `node_max_size` | `3` | Maximum node count. |
| `node_desired_size` | `2` | Desired node count. |
| `vpc_cidr` | `"10.40.0.0/16"` | CIDR for the EKS VPC. |
| `cluster_endpoint_public_access` | `false` | Allow public access to the EKS API endpoint. |
| `cluster_endpoint_public_access_cidrs` | `[]` | CIDR blocks allowed for public endpoint access. Required when public access is enabled. |
| `enable_cluster_creator_admin_permissions` | `false` | Grant the creating identity cluster admin permissions. |
| `cluster_addon_versions` | `{}` | Optional explicit addon versions keyed by name (`coredns`, `kube-proxy`, `vpc-cni`). |

See `variables.tf` for the complete list.

## Outputs

See `outputs.tf` for cluster name, endpoint, CA data, VPC/subnet IDs, OIDC provider details, security group IDs, and Honua control-plane metadata.

## After apply

1. Configure kubectl: `aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region <region>`
2. Verify nodes: `kubectl get nodes`
3. Deploy Honua via the Helm chart, then optionally add the `observability-stack` module for Prometheus and Grafana.
