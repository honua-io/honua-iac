# Azure AKS Module

Provisions a minimal Azure Kubernetes Service (AKS) cluster for integration validation flows.

## What it provisions

- Resource Group
- AKS cluster with a single system node pool

## Example

```hcl
module "aks" {
  source = "../../modules/azure-aks"

  name_prefix = "honua"
  environment = "it"
  location    = "westus"
  authorized_ip_ranges = [
    "198.51.100.10/32",
  ]
}
```

Leave `authorized_ip_ranges` empty only when you intentionally want a public AKS API endpoint. For persistent environments, set trusted operator CIDRs explicitly.

## Outputs

- `environment`
- `resource_group_name`
- `cluster_name`
- `cluster_id`
- `kube_config_raw` (sensitive)
- `control_plane_target_kind = "Kubernetes"`
- `control_plane_backend_name = "honua-gitops-kubernetes"`
- `control_plane_telemetry_policy = "kubernetes-honua-http"`
- `honua_metrics_target = "honua"` for the standard Helm release naming convention
