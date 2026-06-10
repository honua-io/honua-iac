# Operator State Guide

Use a remote backend for every shared or long-lived deployment. The example stacks ship `backend.tf.example` files so operators do not have to invent state layout from scratch.

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

Use S3 plus DynamoDB locking:

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
