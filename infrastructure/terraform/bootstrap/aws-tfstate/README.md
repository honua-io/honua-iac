# AWS Terraform state backend bootstrap

This standalone root creates the remote state substrate required by the AWS
release lane. **Apply it separately, before initializing any product stack.**
Backend creation has its own plan/apply/teardown decision and is never a hidden
side effect of `terraform init`.

It creates:

- an S3 bucket with versioning, default server-side encryption, ownership
  enforcement, public-access blocking, HTTPS-only access, `force_destroy =
  false`, and a bucket policy that denies weakening any of those protections;
- one exclusive object key per stack + environment (extend with
  `state_key_scopes` to serve several stacks from one hardened bucket — two
  scopes can never share a key);
- the locking primitive selected by `lock_mode`;
- a least-privilege managed policy granting access to exactly those state
  objects and their locks, and nothing else.

## Choosing the locking primitive

`lock_mode` defaults to **`s3_native`**: the S3 backend's own lock object
(`use_lockfile = true`), which requires **Terraform >= 1.10** in the roots that
consume this backend. It is the certified default because the lock lives in the
same bucket as the state it guards — inheriting that bucket's encryption,
versioning and public-access denial — instead of needing a second hardened data
store with its own IAM grants and its own failure mode. DynamoDB-based locking
has also been deprecated in the S3 backend since Terraform 1.11, so building the
certified lane on it would mean building on a removal path.

| `lock_mode` | Creates | Backend config | Minimum Terraform |
|---|---|---|---|
| `s3_native` (default) | nothing extra | `use_lockfile = true` | 1.10 |
| `dynamodb` | the lock table | `dynamodb_table = "..."` | 1.5 |
| `both` | the lock table | either | 1.5 |

Operators pinned to Terraform 1.5-1.9 set `lock_mode = "dynamodb"`. Use `both` to
migrate between the two without a locking gap: apply `both`, move the consuming
roots to `use_lockfile`, then apply `s3_native`. Because the lock table carries
`prevent_destroy`, dropping it is a deliberate two-step operation, not a
side effect of flipping a variable.

## Least-privilege backend access

`create_backend_access_policy` (default `true`) emits a managed policy that
grants get/put/delete on exactly the configured state objects and their
`.tflock` siblings, prefix-scoped bucket listing, the four DynamoDB item
operations when a lock table exists, and KMS use when a customer-managed key is
configured. It also carries an explicit deny on bucket administration, so an
identity holding it can never turn off versioning, encryption, or the
public-access block.

Attach it to the **backend access** role (`bootstrap/aws-terraform-oidc`). Never
attach it to the infrastructure deployment role — `bootstrap/aws-exec-identity`
denies that role the state substrate on purpose.

## Use

```bash
terraform init
terraform plan  -var='bucket_name=replace-with-a-globally-unique-name'
terraform apply -var='bucket_name=replace-with-a-globally-unique-name'
terraform output -json backend_contract
```

Then copy the stack's `backend.tf.example` to `backend.tf`, replacing the
placeholders with these outputs. The bootstrap's own state must use a separately
managed backend or an explicitly disposable local state during first apply.

Each shipped `backend.tf.example` names the key its scope produces, so the
scopes and the examples have to agree:

| Stack root | `state_key_scopes` entry | Object key |
|---|---|---|
| `examples/aws` | the `stack_name`/`environment` defaults | `honua/aws/prod/terraform.tfstate` |
| `examples/aws-serverless` | `{ stack_name = "aws-serverless", environment = "prod" }` | `honua/aws-serverless/prod/terraform.tfstate` |
| `examples/aws-eks` | `{ stack_name = "aws-eks", environment = "prod" }` | `honua/aws-eks/prod/terraform.tfstate` |
| `examples/aws-data` | `{ stack_name = "aws-data", environment = "prod" }` | `honua/aws-data/prod/terraform.tfstate` |
| `examples/aws-cert` | `{ stack_name = "aws-cert", environment = "cert" }` | `honua/aws-cert/cert/terraform.tfstate` |

`scripts/check-backend-examples.sh` holds that table's right-hand column to the
files in CI, including the rule that two roots may never share one key.

## Evidence

`backend_contract` and `backend_contract_digest` carry resource identity, key
scope, locking, encryption, access-policy reference, and protection facts only.
They never carry credentials or Terraform state contents. The product contract
stays `unqualified` until an executor supplies the backend digest and
authoritative post-plan/post-apply state lineage from this exact backend —
see `scripts/terraform-backend-identity.sh` and
[`docs/devops/terraform-exact-plan-contract.md`](../../../../docs/devops/terraform-exact-plan-contract.md).

This root creates no IAM users, access keys, OIDC providers, or workload roles.
Short-lived execution identity lives in `bootstrap/aws-terraform-oidc` (backend
access) and `bootstrap/aws-exec-identity` (infrastructure deployment).
