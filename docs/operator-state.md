# Operator State Guide

## Exact plan and state lineage metadata

Before any governed apply or destroy, create a metadata-only contract with `scripts/new-terraform-lineage-contract.ps1`. The caller supplies the saved plan path, a protected file containing only `lineage` and `serial` extracted from `terraform state pull`, exact revision and digest values, and a future expiry. The script hashes the saved plan and emits no state contents, credentials, or secrets.

The artifact is pre-apply evidence only. It does not approve or apply a plan, and `state_after` remains null until a durable actuator and verifier receipt records the resulting lineage, serial, and output contract digest. Never commit the pulled state file or place it in model context, logs, proposals, or receipts.

Example Windows invocation:

```powershell
& .\scripts\new-terraform-lineage-contract.ps1 `
  -PlanPath .\candidate.tfplan `
  -StateMetadataPath .\state-metadata.json `
  -BackendConfigDigest $backendDigest `
  -IacRevision $iacRevision `
  -ProviderLockDigest $lockDigest `
  -InputDigest $inputDigest `
  -ExpiresAtUtc ([DateTime]::UtcNow.AddHours(1)) `
  -OutputPath .\terraform-lineage.json
```

Use a remote backend for every shared or long-lived deployment. The AWS ECS
example ships `backend.tf.example`; apply
`bootstrap/aws-tfstate` separately before activating it so backend creation is
not hidden inside `terraform init`.

## Recommended isolation model

- one backend object key per stack and environment
- one locking primitive per backend namespace
- separate state for data-only stacks, runtime stacks, and observability
- avoid using Terraform workspaces as the main isolation boundary for customer environments

Recommended key layout:

- `honua/aws/prod/terraform.tfstate`
- `honua/aws-serverless/prod/terraform.tfstate`
- `honua/azure/prod/terraform.tfstate`
- `honua/azure-functions/prod/terraform.tfstate`

## AWS backend pattern

Use the `backend_contract` output from `bootstrap/aws-tfstate` to configure S3
plus DynamoDB locking:

```hcl
terraform {
  backend "s3" {
    bucket         = "replace-with-terraform-state-bucket"
    key            = "honua/aws/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "replace-with-terraform-lock-table"
    encrypt        = true
  }
}
```

The bootstrap enables S3 versioning, server-side encryption, public-access
blocking, HTTPS-only access, and DynamoDB point-in-time recovery. Its
`backend_contract_digest` is evidence of backend configuration only; it does
not prove application state lineage. The certified executor must still record
state lineage and serial before and after the exact saved-plan operation.

## Azure backend pattern

Use Azure Storage:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "replace-with-tfstate-resource-group"
    storage_account_name = "replacewithtfstateacct"
    container_name       = "tfstate"
    key                  = "honua/azure/prod/terraform.tfstate"
  }
}
```

## Operational guidance

- create the backend before the first shared `terraform apply`
- do not point multiple stacks at the same backend key
- rotate access to the backend separately from application credentials
- keep state for bootstrap identities separate from runtime state
- when using data-only stacks, store them in a separate backend key from compute stacks so reuse/destroy decisions stay explicit
