# Operator State Guide

## Exact plan and state lineage metadata

Before any governed apply or destroy, create a metadata-only contract with `scripts/new-terraform-lineage-contract.ps1`. The caller supplies the saved plan path, a protected file containing only `lineage` and `serial` extracted from `terraform state pull`, the exact candidate, deployment target, identified actor, workload-identity contract digest, revision and digest values, and a future expiry. The script hashes the saved plan and emits no state contents, credentials, tokens, or secret values.

The artifact is pre-apply evidence only and is always emitted with `qualification_status = "unqualified"`. It does not approve or apply a plan, and `state_after` remains null until a durable actuator and verifier receipt records the resulting lineage, serial, and output contract digest. A consumer must reject the artifact when live backend, actuator, or verifier evidence is absent. Never commit the pulled state file or place it in model context, logs, proposals, or receipts.

Example Windows invocation:

```powershell
& .\scripts\new-terraform-lineage-contract.ps1 `
  -PlanPath .\candidate.tfplan `
  -StateMetadataPath .\state-metadata.json `
  -CandidateDigest $candidateDigest `
  -TargetId "ecs:cluster/service" `
  -ActorId $actorId `
  -WorkloadIdentityContractDigest $workloadIdentityDigest `
  -BackendConfigDigest $backendDigest `
  -IacRevision $iacRevision `
  -ProviderLockDigest $lockDigest `
  -InputDigest $inputDigest `
  -ExpiresAtUtc ([DateTime]::UtcNow.AddHours(1)) `
  -OutputPath .\terraform-lineage.json
```

## Remote state is required; local state is disposable-development only

**Remote state is mandatory for every shared or long-lived deployment.** Two
terminals, two operators, or one operator and one automation run cannot safely
share a local state file: there is no trustworthy lock, no versioned recovery
point, and no lineage another party can verify.

**Local state is allowed only for an explicitly named disposable development
mode** — an account you own, resources you will delete, and evidence nobody will
rely on. It can never satisfy the AWS release/certification lane. The governed
wrappers enforce this rather than merely advising it: without
`--allow-local-state`, `scripts/terraform-exact-plan.sh` and
`scripts/terraform-exact-apply.sh` both fail closed with
`REFUSED[local-state-refused]`, and a plan produced *with* that flag is stamped
`posture.release_qualified = false` so a later apply refuses it too.

A remote backend that names no locking primitive is refused the same way
(`REFUSED[lock-posture-missing]`).

### Backend examples that exist

These AWS stacks ship a `backend.tf.example`. Copy it to `backend.tf` only after
`bootstrap/aws-tfstate` has been applied, and replace every placeholder with that
root's outputs:

- `examples/aws/backend.tf.example`
- `examples/aws-serverless/backend.tf.example`
- `examples/aws-eks/backend.tf.example`
- `examples/aws-data/backend.tf.example`
- `examples/aws-cert/backend.tf.example`

That list is not prose. `scripts/check-backend-examples.sh` runs in CI and fails
if it drifts from the files on disk, if a release-qualified AWS root stops
shipping one, if two roots claim the same object key, or if a root goes back to
declaring a backend inside a tracked `.tf` file. The documentation cannot claim a
`backend.tf.example` that does not exist again.

Backend creation is a **separate, explicitly applied operation**. Apply
`bootstrap/aws-tfstate` on its own, with its own plan/apply/teardown decision, so
the bucket is never a hidden side effect of `terraform init`.

Activate one by copying it — `cp backend.tf.example backend.tf` — never by
editing a tracked file. `backend.tf` is gitignored: the filled-in copy names your
account's state bucket and backend-access role, and those are account identifiers
that do not belong in the repository.

### The locking primitive, and why

The certified default is the **S3 native lock object** (`use_lockfile = true`,
`lock_mode = "s3_native"` in the bootstrap). It requires **Terraform >= 1.10** in
the roots that consume the backend. It is preferred because:

- the lock lives in the same bucket as the state it guards, inheriting that
  bucket's encryption, versioning, and public-access denial rather than needing a
  second hardened data store;
- it removes a whole resource, a second set of IAM grants, and a second failure
  mode from the trust boundary; and
- DynamoDB-based locking has been deprecated in the S3 backend since Terraform
  1.11, so building the certified lane on it would be building on a removal path.

DynamoDB remains fully supported for operators pinned to Terraform 1.5-1.9: set
`lock_mode = "dynamodb"` in `bootstrap/aws-tfstate` and use the commented
`dynamodb_table` line in the backend example instead of `use_lockfile`. Use
`lock_mode = "both"` to migrate between the two without a locking gap.

If a backend asks for `use_lockfile` on Terraform below 1.10, the plan wrapper
refuses with `REFUSED[lock-primitive-unsupported]` rather than silently running
unlocked.

## Short-lived execution identity

The certified path never uses a long-lived IAM user or access key. An existing
SSO session or an OIDC/workload identity is federated into a short-lived STS
session, and four permission surfaces stay separate:

| Lane | Root | Reaches |
|---|---|---|
| Backend access | `bootstrap/aws-terraform-oidc` (+ policy from `bootstrap/aws-tfstate`) | exactly one state object and its lock |
| Infra deployment | `bootstrap/aws-exec-identity` | the stack, in one region; explicitly denied the state substrate |
| Task execution | `modules/aws-ecs` | image pull and secret fetch |
| App runtime | `modules/aws-ecs` | what the application itself may call |

Terraform holds the first two at once without either inheriting the other's
permissions: the `backend "s3"` block assumes the backend role and the
`provider "aws"` block assumes the deployment role.

`bootstrap/aws-ecs`, `bootstrap/aws-serverless`, and `bootstrap/aws-eks` create a
long-lived IAM user. They are **local-only and unsupported for release**: their
`supported_for_release` output is a hard `false`, every principal they create is
tagged `HonuaReleasePosture=unsupported-local-only`, and the governed wrappers
refuse an IAM-user caller with `REFUSED[long-lived-credential-refused]`.

## The evidence contract

`scripts/terraform-backend-identity.sh` emits the non-secret backend identity —
account, partition, region, bucket id and ARN, object key, workspace, locking
posture, encryption/KMS reference, backend access role, and the canonical
`backend_config_digest`. Credential-bearing backend keys are listed by name under
`redacted_config_keys` and never by value.

`scripts/terraform-exact-plan.sh` and `scripts/terraform-exact-apply.sh` produce
the approvable plan metadata and the post-execution receipt. The full field list,
digest rules, and fail-closed matrix are in
[`docs/devops/terraform-exact-plan-contract.md`](devops/terraform-exact-plan-contract.md).

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
with the native lock object:

```hcl
terraform {
  backend "s3" {
    bucket       = "replace-with-terraform-state-bucket"
    key          = "honua/aws/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true

    # Backend access is its own role, separate from the deployment role.
    assume_role = {
      role_arn = "replace-with-backend-access-role-arn"
    }
  }
}
```

On Terraform 1.5-1.9, drop `use_lockfile` and use
`dynamodb_table = "replace-with-terraform-lock-table"` against a bootstrap
applied with `lock_mode = "dynamodb"`.

The bootstrap enables S3 versioning, server-side encryption, public-access
blocking, HTTPS-only access, a bucket policy that denies weakening any of those
protections, and (in DynamoDB mode) point-in-time recovery on the lock table. Its
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
