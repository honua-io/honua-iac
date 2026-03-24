# Azure Functions Terraform Bootstrap Identity

Creates a least-privilege Microsoft Entra application and custom role for Azure Functions style
deployments. Workload identity federation is the preferred path; `create_client_secret` is the
fallback switch.

## Usage
```bash
terraform init
terraform apply
```

## Notes
- Default scope is the current subscription. You can scope to a resource group by
  setting `scope`.
- The custom role is scoped to Function App resources (App Service, Storage, App Insights),
  plus Postgres and Redis for Honua dependencies, and includes scoped
  role-assignment actions required for runtime identity grants.
- Use the `bootstrap_identity_contract` output as the integration contract for CI.
