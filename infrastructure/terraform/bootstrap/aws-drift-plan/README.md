# aws-drift-plan

Two plan-only OIDC roles for nightly drift plans (honua-iac#320, honua-demo-infra#103). On 2026-10-24 the demo's live Lambda alias was moved by hand and nothing noticed for two days; these roles let the nightly plans run.

| Role | Assumed by | Trusts exactly | Plans |
|---|---|---|---|
| `honua-demo-infra-drift-gha` | honua-demo-infra `.github/workflows/drift-plan.yml` | `repo:honua-io/honua-demo-infra:environment:demo-drift` | every stack under `stacks/` (state prefix `demo/aws-demo/`) |
| `honua-iac-bootstrap-drift-gha` | honua-iac `.github/workflows/bootstrap-drift-plan.yml` | `repo:honua-io/honua-iac:environment:bootstrap-drift` | the bootstrap roots in `infrastructure/terraform/bootstrap/drift-roots.json` (state prefix `bootstrap/`) |

Both roles come from `components/aws-github-oidc`, with the account's existing GitHub provider (`create_oidc_provider = false`), exact environment subjects and `cert_permissions_enabled = false`. GitHub puts either the environment or the ref in `sub`, never both. So "trunk only" is the environment's deployment-branch policy: give `demo-drift` and `bootstrap-drift` a policy that allows only `trunk`. Branch and `pull_request` subjects are refused by variable validation.

## Permissions (inline policy `plan-only`)

- **Reads:** control-plane `Describe*`/`Get*`/`List*` for the services in the planned state. For the demo role that is ACM, API Gateway, Batch, Budgets, CloudFront, CloudWatch, CodeArtifact, EC2, ECR, ElastiCache, EventBridge and Scheduler, Location, IAM, KMS, Lambda, Logs, RDS, Redshift subnet groups, Route 53, S3 bucket configuration, Secrets Manager metadata and SNS. The bootstrap role gets IAM reads only. Data-plane reads such as log events, image layers, registry tokens and EC2 password data are excluded.
- **State:** `s3:GetObject` under the role's own state prefix and `s3:ListBucket`. The only writes are `s3:PutObject` and `s3:DeleteObject` on that prefix's `*.tflock` objects, for S3-native locking.
- **Demo only:** `s3:GetObject` (HeadObject) on the published manifest prefix the stack manages. It also gets `secretsmanager:GetSecretValue` on `honua-demo-demo/*`, because refreshing `aws_secretsmanager_secret_version` reads the value. The operator-owned `honua-demo-demo/operation-key-ring` is explicitly denied.
- **Backstop:** a `NotAction` deny covers everything outside the lists above, and a second deny blocks object writes outside `*.tflock`. A broader policy attached later still cannot make either role write.

`tests/policies.tftest.hcl` checks the trust conditions, that every Allow is a read (apart from the lock-file statement), the deny backstop, the disjoint state prefixes and the key-ring deny. The demo role's grants were checked with `aws iam simulate-custom-policy` against every API call a full `terraform plan` of `stacks/aws` makes.

## Apply (operator)

State is in the account's state bucket. Copy `backend.tf.example` to `backend.tf` (gitignored; never commit it), set `bucket`, then init. With Terraform below 1.10, drop `use_lockfile` and use the `dynamodb_table = "honua-tfstate-lock"` line instead.

```sh
cd infrastructure/terraform/bootstrap/aws-drift-plan
sed 's/REPLACE_WITH_STATE_BUCKET_NAME/honua-tfstate-585192672263/' backend.tf.example > backend.tf
terraform init
terraform plan -out=drift-plan.tfplan \
  -var oidc_provider_arn=arn:aws:iam::585192672263:oidc-provider/token.actions.githubusercontent.com \
  -var state_bucket_name=honua-tfstate-585192672263
terraform apply drift-plan.tfplan
```

Expected plan: 4 to add (two roles, two `plan-only` inline policies), nothing else. Then wire the outputs:

```sh
gh api -X PUT repos/honua-io/honua-demo-infra/environments/demo-drift \
  -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST repos/honua-io/honua-demo-infra/environments/demo-drift/deployment-branch-policies -f name=trunk
gh variable set HONUA_DEMO_DRIFT_ROLE_ARN -R honua-io/honua-demo-infra --env demo-drift \
  --body "$(terraform output -raw demo_infra_drift_role_arn)"

gh api -X PUT repos/honua-io/honua-iac/environments/bootstrap-drift \
  -F 'deployment_branch_policy[protected_branches]=false' -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST repos/honua-io/honua-iac/environments/bootstrap-drift/deployment-branch-policies -f name=trunk
gh variable set HONUA_BOOTSTRAP_DRIFT_ROLE_ARN -R honua-io/honua-iac --env bootstrap-drift \
  --body "$(terraform output -raw iac_bootstrap_drift_role_arn)"
```

The demo drift plan also needs the environment secret `HONUA_DEMO_ADMIN_PASSWORD`; see the honua-demo-infra README.

This root's own state lives under `bootstrap/`, and it is listed in `drift-roots.json`, so the bootstrap drift plan covers it too.
