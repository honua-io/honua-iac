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
  - `sub` matches the scoped patterns — default
    `repo:<owner>/<repo>:*`, tightenable to a ref or a GitHub **Environment**
    (e.g. `repo:honua-io/honua-server:environment:cert`) via
    `github_oidc_subjects`.
- A least-privilege inline **permission policy** scoped by Resource/Condition to
  the `honua-cert-*` surface: Batch `SubmitJob` on the cert
  queue/job-definitions; job-definition `Register`/`Deregister`/`Tag`/`Untag`
  on the cert job-definition prefix (for the tests' ephemeral per-run job
  definitions tagged `honua-cert-run=<id>`); `Terminate`/`Cancel` on the
  account/region job namespace (Batch job ARNs are un-prefixable UUIDs);
  Batch/ECS/ELBv2 describe; ECS `UpdateService`/`DescribeServices` on the
  `honua-cert-*` service surface and ELBv2 `ModifyRule`/`ModifyListener` on the
  passed-in cert listener/rule ARNs (the ECS/ALB weighted-cutover cell, gated on
  `cert_alb_modify_resource_arns`); Lambda
  `Invoke`/`GetFunction`/`GetAlias`/`UpdateAlias`/`PublishVersion`
  on `honua-cert-*` functions; S3 read/write **+ object tagging** on the cert
  artifact bucket; CloudWatch Logs/metric read; and `iam:PassRole` (scoped via
  `iam:PassedToService` to batch/ecs-tasks) for the GP job + execution roles.

## Trust scoping

| Goal | Set |
|---|---|
| Any workflow on the repo | default (`github_owner` + `github_repository`) |
| Only the `cert` GitHub Environment | `github_oidc_subjects = ["repo:honua-io/honua-server:environment:cert"]` |
| A single branch | `github_oidc_subjects = ["repo:honua-io/honua-server:ref:refs/heads/cert"]` |

The tightest practical scope for a **dispatched** cert workflow is a dedicated
GitHub Environment, because `workflow_dispatch` runs do not carry a stable PR
ref. Pin to `:environment:cert` and require that environment in the workflow.

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
