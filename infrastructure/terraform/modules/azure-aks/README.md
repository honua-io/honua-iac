# Azure AKS Module

Provisions an Azure Kubernetes Service (AKS) cluster with a system node pool, autoscaling, and RBAC.

## Quick start (dev)

```hcl
module "aks" {
  source = "../../modules/azure-aks"

  environment = "dev"
  location    = "westus"

  sku_tier               = "Free"
  local_account_disabled = false  # Allow local kubeconfig in dev
}
```

> Leave `authorized_ip_ranges` empty only when you intentionally want a public AKS API endpoint. For persistent environments, set trusted operator CIDRs explicitly.

## Production example

```hcl
module "aks" {
  source = "../../modules/azure-aks"

  environment = "prod"
  name_prefix = "honua"
  location    = "eastus"

  # Cluster
  sku_tier           = "Standard"
  kubernetes_version = "1.30"

  # Node pool
  node_vm_size         = "Standard_D4s_v3"
  node_count           = 3
  auto_scaling_enabled = true
  node_min_count       = 2
  node_max_count       = 8
  node_os_disk_size_gb = 128

  # Access
  local_account_disabled = true
  authorized_ip_ranges   = ["203.0.113.0/24"]

  # Networking
  network_plugin = "azure"
  network_policy = "azure"

  # Observability
  log_analytics_workspace_id = var.log_analytics_workspace_id

  tags = {
    Project     = "honua"
    Environment = "prod"
  }
}
```

## Networking

The module uses the Azure CNI network plugin by default:

- **azure** (default): Pods get VNet IPs directly. Better performance, tighter NSG integration.
- **kubenet**: Pods use an overlay network. Simpler, uses fewer VNet IPs.

Network policy is enforced via the Azure or Calico provider (set `network_policy`). The load balancer SKU is always `standard`.

## Security

- **RBAC**: Kubernetes RBAC is always enabled.
- **Local accounts**: Disabled by default (`local_account_disabled = true`). Set to `false` for dev clusters where Azure AD is not configured.
- **API server access**: Restrict with `authorized_ip_ranges`. When set, only listed CIDRs can reach the API server.
- **System-assigned identity**: The cluster uses a system-assigned managed identity for Azure resource operations.
- **Diagnostics**: When `log_analytics_workspace_id` is provided, API server, audit, controller manager, and scheduler logs are sent to Log Analytics.

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `location` | `"westus"` | Azure region. |
| `sku_tier` | `"Free"` | AKS SKU tier (`Free`, `Standard`, `Premium`). Use `Standard` for production SLA. |
| `kubernetes_version` | `""` | AKS Kubernetes version. Empty uses the provider default. |
| `node_vm_size` | `"Standard_D2s_v3"` | VM size for the system node pool. |
| `node_count` | `2` | Static node count (used when autoscaling is disabled). |
| `auto_scaling_enabled` | `true` | Enable cluster autoscaler on the default node pool. |
| `node_min_count` | `1` | Minimum node count when autoscaling is enabled. |
| `node_max_count` | `5` | Maximum node count when autoscaling is enabled. |
| `node_os_disk_size_gb` | `64` | OS disk size in GB. |
| `network_plugin` | `"azure"` | Network plugin (`azure` or `kubenet`). |
| `network_policy` | `"azure"` | Network policy provider (`azure`, `calico`, or `""`). |
| `local_account_disabled` | `true` | Disable local Kubernetes accounts. |
| `authorized_ip_ranges` | `[]` | CIDR ranges authorized to access the AKS API server. |
| `log_analytics_workspace_id` | `""` | Log Analytics workspace ID for diagnostic logs. Empty to disable. |

See `variables.tf` for the complete list.

## Outputs

See `outputs.tf` for cluster name, resource ID, kubeconfig, resource group, and Honua control-plane metadata.

## After apply

1. Configure kubectl: `az aks get-credentials --resource-group $(terraform output -raw resource_group_name) --name $(terraform output -raw cluster_name)`
2. Verify nodes: `kubectl get nodes`
3. Deploy Honua via the Helm chart, then optionally add the `observability-stack` module for Prometheus and Grafana.
