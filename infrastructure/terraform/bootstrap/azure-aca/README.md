# Azure Container Apps Terraform Bootstrap Identity

Creates a least-privilege Microsoft Entra application and custom role for the
`modules/azure-aca` Terraform module. Workload identity federation is the preferred path;
`create_client_secret` is the fallback switch.

## Usage
```bash
terraform init
terraform apply
```

## Notes
- Default scope is the current subscription. You can scope to a resource group by
  setting `scope`.
- The custom role is scoped to the ACA module's resource types (Container Apps,
  Log Analytics, Postgres Flexible Server, Redis, Key Vault, Managed Identity,
  Storage, Resource Groups) plus scoped role-assignment actions required for
  runtime identity grants.
- Use the `bootstrap_identity_contract` output as the integration contract for CI.
