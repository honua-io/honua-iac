# Azure AKS Terraform Service Account

Creates a service-scoped Azure AD service principal and custom role for the
`modules/azure-aks` Terraform module.

## Usage
```bash
terraform init
terraform apply
```

## Notes
- Default scope is the current subscription. You can scope to a resource group by
  setting `scope`.
- The custom role is scoped to AKS resources plus required networking and
  resource group permissions.
- A custom role is used instead of a built-in broad role so the bootstrap surface stays anchored to
  the module's resource types.
- Shared permission fragments live in `bootstrap/shared/azure-bootstrap-role-actions.json`; this
  root composes the AKS-specific delta on top of those shared actions.
- When `create_client_secret = true`, use `client_secret_duration_hours` as the explicit rotation window.
