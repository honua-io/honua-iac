# aws-validation-reaper

OIDC role for `sweep-orphaned-validation-infra.sh`, which runs in two places:

- `terraform-validation-infra-reaper.yml`: the nightly scheduled sweep, plus manual dispatch. It runs in the protected GitHub environment `aws-validation-reaper`.
- `terraform-manual-validation.yml`: the always-step that reaps its own cell. It runs in environment `terraform-ephemeral` or `terraform-live-approval`.

The repository variable `HONUA_AWS_VALIDATION_REAPER_ROLE_ARN` must name this role. While the variable is unset, the scheduled reaper concludes `skipped` (honua-release#376 R18/R21), and stranded cells accumulate until they exhaust the VPC quota.

## Trust and permissions

**Trust.** Only the exact `repo:honua-io/honua-iac:environment:<name>` subjects in `oidc_subjects` can assume the role. Branch subjects and wildcard subjects are rejected.

**Grants.** The role gets the reads the sweep needs to prove that a resource is orphaned, including `cloudtrail:LookupEvents` for the legacy release-cell VPC pass. It also gets the delete verbs of the sweep's teardown. It gets no create, modify, tag, IAM or STS grant.

**Denies.** These are the independent backstop, mirroring the release-cell guardrail:
- any region outside `sweep_regions`;
- role chaining, and all of IAM (IAM principals are `sweep-orphaned-validation-iam.sh`'s job);
- any retagging;
- anything tagged `Environment=cert|standing|demo`, `Lifecycle=standing|demo`, `Owner=release-standing` or `Purpose=public-demo`;
- `honua-cert-*` and `honua-demo-*` named Lambda, RDS, ECS, Secrets Manager, Logs and ElastiCache resources.

## Apply (operator)

```sh
terraform -chdir=infrastructure/terraform/bootstrap/aws-validation-reaper init
terraform -chdir=infrastructure/terraform/bootstrap/aws-validation-reaper apply \
  -var oidc_provider_arn=arn:aws:iam::585192672263:oidc-provider/token.actions.githubusercontent.com
gh variable set HONUA_AWS_VALIDATION_REAPER_ROLE_ARN -R honua-io/honua-iac \
  --body "$(terraform -chdir=infrastructure/terraform/bootstrap/aws-validation-reaper output -raw role_arn)"
```

Add required reviewers to the `aws-validation-reaper` environment if a scheduled sweep should wait for approval.
