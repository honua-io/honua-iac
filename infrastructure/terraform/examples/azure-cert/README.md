# examples/azure-cert — Honua real-Azure certification tier

The Azure parallel of [`examples/aws-cert`](../aws-cert). A Honua-owned stack
that certifies the **GP-over-Azure-Batch** path against **real Azure** (no
emulator), with **GitHub-OIDC federation** so a dispatched cert workflow can
`terraform apply` and drive Batch with **no client secret**.

## What it provisions

- **`modules/azure-gp`** with `enable_azure_gp_substrate = true` — the durable
  **single-pool** GP substrate: a Batch account, one autoscaling
  **scale-to-zero** pool, the worker-gdal ACR, the task identity, and blob
  output staging. See the [module README](../../modules/azure-gp/README.md) for
  the single-pool rationale and the autoscale formula.
- An **OIDC-federated cert identity** — a `azurerm_user_assigned_identity` + an
  inline `azurerm_federated_identity_credential` (issuer
  `token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`,
  `sub` pinned to the cert repo/environment). This is the azurerm equivalent of
  the AWS GitHub-OIDC provider, copied from
  `components/cloud-demo-smoke-credentials`.
- **Role assignments** the cert identity needs, least-privilege and scoped to
  this stack: `Contributor` on the Batch account (submit/observe/terminate),
  `AcrPush` on the worker-gdal ACR (push the GP image), and
  `Storage Blob Data Contributor` on the output account.

## Why OIDC (no secret)

The dispatched GitHub Actions cert workflow uses `azure/login@v2` with
`client-id` / `tenant-id` / `subscription-id` (all non-secret, output below) and
exchanges its GitHub OIDC token for an Azure AD token. No client secret is
committed anywhere — the trust is established by the federated credential's `sub`
scope.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars (location, github_oidc_subject, ...)

terraform -chdir=infrastructure/terraform/examples/azure-cert init
terraform -chdir=infrastructure/terraform/examples/azure-cert plan
terraform -chdir=infrastructure/terraform/examples/azure-cert apply
```

After apply, wire the OIDC outputs into the cert workflow as repo
secrets/variables:

```bash
terraform output cert_identity_client_id   # -> AZURE_CLIENT_ID
terraform output tenant_id                 # -> AZURE_TENANT_ID
terraform output subscription_id           # -> AZURE_SUBSCRIPTION_ID
```

The GP runtime contract the server/devops adapter read:

```bash
terraform output gp_batch_account_url      # azure.batch.account_url
terraform output gp_pool_id                # azure.batch.pool_id
terraform output gp_output_container_url    # azure.storage.output_container_url
terraform output gp_control_plane_backend_name  # honua-azure-batch
```

## Topology

GP execution here follows the same control-plane topology as AWS Batch: an
always-on Honua control plane (ACA/AKS/on-prem) submits to ephemeral
scale-to-zero Batch compute. There is no external Azure Scheduler / Event Grid
trigger — the scheduler lives in the control plane. See the
[module README](../../modules/azure-gp/README.md#deployment-topology--the-control-plane-decision).

## Cost

The pool autoscales to **zero** between jobs, and low-priority (Spot) nodes are
the default. Apply destroys cleanly (`terraform destroy`) when certification is
done. Do **not** leave the stack applied unattended; there is no budget
guardrail in this example (unlike `examples/aws-cert`, Azure budgets are a
subscription-level construct configured separately).
