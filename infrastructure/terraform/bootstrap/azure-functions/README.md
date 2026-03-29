# Azure Functions Terraform Bootstrap Identity

Creates a service-scoped Microsoft Entra application and custom role for Azure Functions style
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
- A custom role is used instead of a built-in broad role so the bootstrap surface stays anchored to
  the module's resource types even as the runtime grows.
- Shared permission fragments live in `bootstrap/shared/azure-bootstrap-role-actions.json`; this
  root composes only the Functions-specific delta on top of those shared actions.
- Use the `bootstrap_identity_contract` output as the integration contract for CI.
- When `create_client_secret = true`, use `client_secret_duration_hours` as the explicit rotation window.
