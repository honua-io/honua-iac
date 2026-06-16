# cloud-demo-smoke-credentials — seeded demo smoke credential store (honua-iac#30)

Terraform component that provisions the **managed credential + secret store**
for the seeded Honua Cloud demo smoke. It is the IaC half of
[honua-iac#30](https://github.com/honua-io/honua-iac/issues/30) REQ-002 /
REQ-004 / NFR-001: it gives the already-merged scheduled smoke workflow
(`.github/workflows/cloud-demo-smoke.yml`) a way to authenticate against the
seeded tenant **without any secret being committed to this repo**.

Contract source of truth: `honua-sdk-js/examples/cloud-demo-services.json` and
`examples/cloud-demo.env.example` (the `HONUA_CLOUD_DEMO_*` / `VITE_*` names).

## What this provisions

| Resource | Purpose |
|---|---|
| Resource group | Holds the smoke credential store |
| User-assigned identity | The smoke's login identity (no client secret) |
| Federated identity credential | OIDC trust for `azure/login@v2` from the scheduled GitHub workflow, pinned to one branch subject |
| Key Vault (`standard`, purge-protected) | The managed secret store (REQ-002) |
| Access policy (apply principal) | Get/List/Set on secret values — used to rotate |
| Access policy (smoke identity) | **Get/List only** — least privilege for the scheduled run |
| Secret slots: `honua-cloud-demo-api-key`, `honua-cloud-demo-bearer-token` | Read-only smoke credentials (always present) |
| Secret slots: `honua-cloud-demo-write-token`, `honua-cloud-demo-reset-token`, `honua-cloud-demo-reset-url` | **Only when `enable_writable_lane = true`** — the guarded writable lane |

A `check` block enforces NFR-001: `enable_writable_lane = true` fails unless a
`cloud_demo_reset_url` is supplied, so writes can never be turned on without a
reset path. The minted token slots are placeholder strings managed with
`ignore_changes = [value]`, so an operational rotation never shows as a
Terraform diff.

## What this does NOT do

- It does **not** seed the demo data or stand up the demo API — that is the
  Honua demo-environment Terraform (`examples/aws-demo`, and the Azure
  equivalent when it lands) plus the server-side seeding in
  [honua-server#1688](https://github.com/honua-io/honua-server/issues/1688).
- It does **not** fix the live DNS/TLS (`cloud.honua.io` still CNAMEs to GitHub
  Pages — tracked in honua-iac#37). Until that is corrected the smoke will reach
  the wrong host, regardless of credentials.
- It does **not** mint the demo API keys/tokens. Those come from the seeded
  Honua server (admin API key issuance / `honua-server#1688`); the operator
  pastes the minted values into the vault slots below.

## Operator steps (require live Azure — NOT run here)

This was authored and statically validated only (`terraform fmt` /
`terraform validate`). It has never been applied. To deploy:

```bash
cd infrastructure/terraform/components/cloud-demo-smoke-credentials
cp terraform.tfvars.example terraform.tfvars   # edit OIDC subject + IP rules

az login                                        # operator-supplied credentials
terraform init
terraform plan  -out tfplan
terraform apply tfplan
```

Then populate the secret slots with the minted demo credentials (values come
from the seeded server, NOT from Terraform):

```bash
KV=$(terraform output -raw key_vault_name)

az keyvault secret set --vault-name "$KV" --name honua-cloud-demo-api-key      --value "<read api key from seeded server>"
az keyvault secret set --vault-name "$KV" --name honua-cloud-demo-bearer-token --value "<bearer token, if the demo needs one>"
# Writable lane (only if enable_writable_lane=true):
az keyvault secret set --vault-name "$KV" --name honua-cloud-demo-write-token  --value "<write token>"
az keyvault secret set --vault-name "$KV" --name honua-cloud-demo-reset-token  --value "<reset token>"
```

Wire the scheduled GitHub Actions smoke (`cloud-demo-smoke.yml`) to this store.
The non-secret values come straight from outputs:

```bash
terraform output cloud_demo_repo_variables   # set these as repo VARIABLES (vars.*)
terraform output smoke_identity_client_id    # -> repo secret AZURE_CLIENT_ID
terraform output tenant_id                   # -> repo secret AZURE_TENANT_ID
terraform output subscription_id             # -> repo secret AZURE_SUBSCRIPTION_ID
```

The smoke workflow logs in with `azure/login@v2` (federated, no secret), reads
the vault, and exports each secret as its `HONUA_CLOUD_DEMO_*` env. Because the
smoke identity has **Get/List only**, a leaked workflow log cannot rotate or
delete a credential.

## Credential rotation (issue AC: "rotate read/write/reset without changing browser sample code")

Rotation is **operational**, not a code change. Browser samples consume only
`VITE_*` read-scoped wiring (base URL + read API key); the write/reset secrets
never reach the browser (REQ-004). To rotate:

1. Mint the new credential on the seeded server (new API key / write / reset
   token).
2. Overwrite the slot in place — this creates a new secret version, the old one
   stays recoverable:
   ```bash
   az keyvault secret set --vault-name "$KV" --name honua-cloud-demo-api-key --value "<new key>"
   ```
3. Re-run the scheduled smoke (`workflow_dispatch`) to confirm the new value
   works. No Terraform apply, no edit to honua-sdk-js sample code, no change to
   any `VITE_*` value.
4. Revoke the old credential on the server once the smoke is green.

Because the read key the browser uses and the write/reset tokens the smoke uses
are separate slots, read-key rotation never touches the write/reset path and
vice versa.

## Validation status

- `terraform fmt -check` and `terraform validate` (with `azurerm` provider,
  `-backend=false`) pass — static only.
- **Blocked on live Azure**: `terraform plan`/`apply`, the actual federated
  login, secret population, and a green scheduled smoke all require operator
  Azure credentials and the honua-iac#37 DNS/TLS fix. None were run.
