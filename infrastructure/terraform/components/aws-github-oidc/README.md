# aws-github-oidc

First-class **GitHub Actions → AWS OIDC** federation for Honua. This is the
**first** `aws_iam_openid_connect_provider` in this repo (modeled on the Azure
federated-identity precedent in
`components/cloud-demo-smoke-credentials`). It lets a dispatched GitHub Actions
workflow assume a least-privilege AWS role **without a long-lived access key**.

Built for the real-AWS **certification** tier (`examples/aws-cert`,
honua-iac#2164), but reusable for any repo/workflow → AWS OIDC need.

## What it creates

- An `aws_iam_openid_connect_provider` for
  `https://token.actions.githubusercontent.com` with audience
  `sts.amazonaws.com` (skippable via `create_oidc_provider = false` — only one
  provider per issuer URL is allowed per account; reuse an existing one with
  `existing_oidc_provider_arn`).
- An `aws_iam_role` whose **trust policy** authorizes
  `sts:AssumeRoleWithWebIdentity` only when:
  - the principal is this OIDC provider,
  - `aud == sts.amazonaws.com`, and
  - `sub` **exactly equals** (`StringEquals`, no wildcards) one subject —
    default `repo:<owner>/<repo>:ref:refs/heads/trunk` (`github_oidc_ref`),
    or a GitHub **Environment** subject via `github_oidc_environment`
    (e.g. `repo:honua-io/honua-server:environment:cert`), or the explicit
    `github_oidc_subjects` override.
- A least-privilege inline **permission policy** scoped by Resource/Condition to
  the `honua-cert-*` surface: Batch `SubmitJob` on the **standing** cert
  queue/job-definition pool (`resource_name_prefix`, e.g. `honua-cert-cert-*`);
  job-definition `Register`/`Deregister`/`Tag`/`Untag` scoped to a **DISJOINT
  run-only namespace** (`jobdef_lifecycle_name_prefix`, e.g. `honua-certrun-*`)
  for the tests' ephemeral per-run job definitions tagged `honua-cert-run=<id>`.
  The submit and register scopes are kept disjoint so the role cannot compose
  `Register`(role-carrying)`+SubmitJob` into arbitrary-code-as-GP-role, and cannot
  `Deregister` the standing pool. Also: `Terminate`/`Cancel` on the account/region
  job namespace (Batch job ARNs are un-prefixable UUIDs); Batch/ECS/ELBv2 describe;
  ECS `UpdateService`/`DescribeServices` on the `honua-cert-*` service surface and
  ELBv2 `ModifyRule`/`ModifyListener` on the passed-in cert listener/rule ARNs (the
  ECS/ALB weighted-cutover cell, gated on `cert_alb_modify_resource_arns`); Lambda
  `Invoke`/`GetFunction`/`GetAlias`/`UpdateAlias`/`PublishVersion`
  on `honua-cert-*` functions; S3 read/write **+ object tagging** on the cert
  artifact bucket; CloudWatch Logs/metric read; and `iam:PassRole` (scoped via
  `iam:PassedToService` to batch/ecs-tasks) for **only** the ECS/ALB cutover
  execution role — the GP job/execution roles are intentionally NOT passable (the
  standing definitions already carry them; passing them would reopen the escalation).

The Lambda certification lane's lifecycle grants are not part of this
component. These are the ECR mirror, tagged per-run function
create/invoke/delete, log cleanup, and `iam:PassRole` for the dedicated Lambda
execution role. `examples/aws-cert/lambda-preview-cert.tf` attaches them as a
separate inline policy on this role (honua-iac#168). It changes none of this
component's inputs, its trust policy or its subjects, and the policy gate
fails if that file declares any federation or trust of its own.

## Trust scoping

Every subject is matched with `StringEquals`; wildcard subjects are refused at
plan time. The earlier repo-wide `repo:<owner>/<repo>:*` default (any branch,
any PR, any environment) is gone.

| Goal | Set |
|---|---|
| Jobs on the protected `trunk` branch (no `environment:`) | default (`github_owner` + `github_repository`, `github_oidc_ref = "refs/heads/trunk"`) |
| Only the `cert` GitHub Environment | `github_oidc_environment = "cert"` or `github_oidc_subjects = ["repo:honua-io/honua-server:environment:cert"]` |
| A different single branch | `github_oidc_ref = "refs/heads/cert"` |

A job that declares `environment:` presents the environment subject, not the
ref subject, so pin such jobs by environment and give that environment a
deployment-branch policy that allows only `trunk`.

The tightest practical scope for a **dispatched** cert workflow is a dedicated
GitHub Environment, because `workflow_dispatch` runs do not carry a stable PR
ref. Pin to `:environment:cert` and require that environment in the workflow.

## Reusing the federation for another role

`cert_permissions_enabled = false` attaches no certification policy, and
`role_name` names the role. The consumer then attaches its own policy to the
`role_name` output. `bootstrap/aws-drift-plan` builds its two plan-only drift
roles this way. The trust policy and its exact-subject rules are unchanged.
Existing consumers keep the policy at `aws_iam_role_policy.permissions[0]`
(a `moved` block covers the address change), along with their historical role
name.

## Hosted-pilot bootstrap executor role (optional)

`hosted_pilot_bootstrap_role_enabled = true` adds a second role,
`honua-hosted-pilot-bootstrap-gha`, for the `bootstrap` job of honua-iac's
`.github/workflows/hosted-pilot-bootstrap.yml`. It replaces the static
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` repository secrets.

- Trust: this OIDC provider, `aud = sts.amazonaws.com`, and `sub` exactly
  `repo:honua-io/honua-iac:environment:terraform-ephemeral`
  (`hosted_pilot_bootstrap_oidc_subjects`). GitHub never puts the ref and the
  environment in one `sub`, so the trunk pin comes from the workflow's
  `github.ref == 'refs/heads/trunk'` guard plus a trunk-only deployment-branch
  policy on the `terraform-ephemeral` environment. Set that policy.
- Permissions: whatever reviewed managed policies you pass in
  `hosted_pilot_bootstrap_policy_arns` (required; AWS administrator policies are
  refused). Attach the policy the static-key principal holds today.
- Optional `hosted_pilot_bootstrap_permissions_boundary_arn`.

Operator rollout:

1. Apply this component in the hosted-pilot account with
   `hosted_pilot_bootstrap_role_enabled = true` and the policy ARNs
   (`create_oidc_provider = false` plus `existing_oidc_provider_arn` if the
   account already has the GitHub provider).
2. Set the repository variable `HONUA_AWS_HOSTED_PILOT_BOOTSTRAP_ROLE_ARN` in
   `honua-io/honua-iac` to the `hosted_pilot_bootstrap_role_arn` output.
3. Restrict the `terraform-ephemeral` environment's deployment branches to
   `trunk`.
4. Run the workflow once with `mode=plan`, then delete the
   `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` repository and environment
   secrets and deactivate and delete the IAM user access key behind them.

## Usage in a workflow

```yaml
permissions:
  id-token: write   # required to mint the OIDC token
  contents: read
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: ${{ vars.HONUA_CERT_ROLE_ARN }}   # this module's role_arn output
      aws-region: us-east-1
```

## Notes

- AWS validates the GitHub OIDC token against a trusted root CA, so the
  `thumbprint_list` is effectively a formality; the well-known GitHub
  intermediate thumbprint is the default.
- Do not commit `terraform.tfvars` — copy from `terraform.tfvars.example`.
- Validated in CI (`terraform-ci.yml` roots list); no `apply` is run by CI.
