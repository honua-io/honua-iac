# AGENTS.md

## Overview

Operator-focused Terraform (Infrastructure-as-Code) for deploying the Honua
platform into a user's own AWS or Azure account. The repo provides reusable
Terraform modules, deployable example stacks for each runtime target
(ECS/Fargate, Azure Container Apps, AWS Lambda, Azure Functions, EKS, AKS),
optional least-privilege bootstrap identities, and maintainer-only validation
automation. There is no application code here — only Terraform, shell scripts,
one Node ESM script, and docs.

## Tech Stack

- **Terraform** `>= 1.5, < 2.0` (HCL).
- Providers: `hashicorp/aws` (`>= 5.0, < 7.0`), `hashicorp/azurerm`,
  `hashicorp/random` (`>= 3.5, < 4.0`), `hashicorp/null` (`>= 3.2, < 4.0`),
  plus kubernetes/helm in the observability and k8s paths. Check each
  module's `versions.tf` for exact constraints.
- **Bash** scripts (`set -euo pipefail` convention) under `scripts/` and
  `infrastructure/terraform/validation/scripts/`.
- **Node.js** ESM for `scripts/write-cloud-demo-smoke-env-summary.mjs`.
- CI tooling: `tflint`, `checkov==3.2.497` (pinned), Python 3.11, ripgrep.
- CI: GitHub Actions (`.github/workflows/`). Default branch is `trunk`.

## Setup

Install Terraform 1.5+ and the relevant cloud CLI/credentials (AWS or Azure)
before running anything. No language package manager is used at the repo root.

Operator path: pick a stack, copy its tfvars example, fill in
secrets/images, then init/plan/apply.

```bash
cp infrastructure/terraform/examples/aws/terraform.tfvars.example \
   infrastructure/terraform/examples/aws/terraform.tfvars
```

## Commands

Build/plan/apply a stack (replace `aws` with `azure`, `aws-serverless`,
`azure-functions`, `aws-eks`, `azure-aks`, `observability`, `aws-data`,
`azure-data`):

```bash
terraform -chdir=infrastructure/terraform/examples/aws init
terraform -chdir=infrastructure/terraform/examples/aws plan
terraform -chdir=infrastructure/terraform/examples/aws apply
```

Format and validate (mirrors CI `static-validate`):

```bash
terraform fmt -check -recursive infrastructure/terraform
terraform fmt -check -recursive docs/devops/examples
# per-root, with backend disabled:
terraform -chdir=<root> init -backend=false -input=false -no-color
terraform -chdir=<root> validate -no-color
```

Policy gate / lint (mirrors CI `policy-gates`; requires tflint, checkov,
ripgrep on PATH):

```bash
HONUA_TERRAFORM_POLICY_STRICT=true \
  ./infrastructure/terraform/validation/scripts/shared/terraform-policy-gate.sh
# convenience wrapper (delegates to the above):
./scripts/terraform-policy-gate.sh
```

Maintainer integration / drift validation (thin wrappers in `scripts/`
that exec into `infrastructure/terraform/validation/scripts/`):

Use the `scripts/run-{aws,azure,eks,aks,k8s}-terraform-integration.sh` wrappers or
`scripts/run-terraform-drift-detection.sh` for the authorized target.

Static validation, policy gates and focused Terraform/build-host tests are defined in
`.github/workflows/`; live integration and drift checks require explicit authorization.

## Architecture

- **modules/** — reusable building blocks, one per runtime target. Each has
  `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, and a `README.md`:
  `aws-ecs` (ECS/Fargate + RDS + ALB), `azure-aca` (Container Apps +
  PostgreSQL Flexible Server + Key Vault), `aws-serverless` (Lambda + API
  Gateway + RDS), `azure-functions` (Functions + PostgreSQL), `aws-eks`,
  `azure-aks`, `aws-data`, `azure-data`, `observability-stack`
  (Prometheus + Grafana).
- **examples/** — thin deployable stacks that wire a module to a backend and
  expose `terraform.tfvars.example`. Outputs include `honua_url` and DB
  endpoint/FQDN.
- **bootstrap/** — optional least-privilege deployment identities per target.
- **validation/** — maintainer-only QA: policy gates, live applies, drift
  detection, isolated under `validation/scripts/{aws,azure,k8s,shared}` so it
  never mixes into operator stacks.
- Module publish tiering (Tier 1 publish-candidate vs Tier 3 internal) is in
  `docs/module-publishing-decision.md`.

## Directory Layout

```
infrastructure/terraform/
  modules/      reusable modules (per cloud/runtime)
  examples/     deployable stacks (operator entrypoints)
  bootstrap/    optional least-privilege identities
  validation/   maintainer QA scripts (aws/azure/k8s/shared)
scripts/        repo-root wrappers + gh secret/var bootstrap + tf-secrets helpers
  lib/          shared bash (tf-secret-catalog.sh)
docs/           operator-deployment.md, module-publishing-decision.md
  devops/       terraform-validation.md, examples/ (validated HCL snippets)
  features/     capability summary
.github/workflows/  CI, validation, drift and deployment workflows
```

## Release declarations

`release/component-versions.json` is read by the honua-release nightly resolver at the exact commit it selects. The resolver refuses this component when the file is missing or invalid, so any bump of a contract or schema version this repository serves must land in the same pull request as the matching change to that file.

## Conventions & Gotchas

- Every Terraform root pins `required_version` and provider versions in
  `versions.tf` — keep new roots consistent and add them to the `roots` list
  in `.github/workflows/terraform-ci.yml` so they get validated.
- Never declare a `backend` block inside a tracked `.tf` file. A release-qualified
  AWS root ships `backend.tf.example`, the operator copies it to `backend.tf`
  (gitignored), and `scripts/check-backend-examples.sh` enforces that plus
  encryption, locking, key exclusivity, and the file list in
  `docs/operator-state.md`.
- CI runs on PRs and on push to `trunk`, but only for paths matching the
  `infrastructure/terraform/**`, listed `scripts/*`, and `docs/devops/**`
  filters. Adding files outside those globs won't trigger Terraform CI.
- `docs/devops/examples/**` HCL is fmt-checked and validated in CI — treat it
  as real Terraform, not freeform docs.
- `scripts/*.sh` are wrappers that `exec` into the canonical scripts under
  `infrastructure/terraform/validation/scripts/`; edit the canonical copy.
- The policy gate honors `HONUA_TERRAFORM_POLICY_STRICT` — `true` fails on any
  violation; unset/`false` only warns. CI runs it strict.
- Secrets: `scripts/tf-secrets.local.sh` and `scripts/tf-pass-insert.local.sh`
  are gitignored; use `scripts/tf-secrets.local.example.sh` as the template.
  Never commit real secrets or `terraform.tfvars`.
- `**/.terraform/` is gitignored; do not commit provider plugins or state.
- Do not run `terraform apply` against real cloud accounts unless explicitly
  asked — applies create billable infrastructure.

## Review guidelines
Reviews (people, Codex, Claude) judge the lines a PR adds or changes by Robert C. Martin's *Clean Code*
and cite smell codes ([rubric](https://github.com/honua-io/.github/blob/main/clean-code/RUBRIC.md)). The
`Clean code` PR check enforces what a tool can decide; `quality-exception: <reason>` in the PR body is logged.

BLOCKING:
- G5 duplication: search first; reuse or consolidate, never copy a handler, parser or validator.
- C1 history, ticket/PR refs or reviewer notes in code; C2-C4 obsolete, redundant or rambling comments;
  C5 commented-out code. Comment only what the code cannot say.
- XML doc comments (`///`) in application code; published SDKs keep at most a one-line `<summary>`
  on public members.
- N1 names that hide intent; F1 more than 3 parameters; F2 output arguments; F3 boolean flag arguments.
- Over budget with no reason in the PR: functions ~40 lines or 2 nesting levels; classes, files ~400 lines.

WARNING: the rubric's other smells (N2-N7, G6-G36, T1-T9), e.g. G25 magic numbers or G12
single-implementation interfaces.

<!-- fleet:begin v3 sha256=4faeba041ae102508d105847af58b407641cbfdf1ae506488819a2ccdbe73e29 -->
## Fleet rules (all Honua repos)

Generated from the org fleet-rules source; do not edit this block. Start with org skill `honua-system-map`.

1. Author commits as the repository owner's configured git identity. No AI attribution in commits or PR bodies.
2. Use a separate worktree per task, off the default branch, on durable disk. Include current trunk before opening a PR. No shared-checkout edits or git stash; preserve work with commits.
3. Run .NET builds and tests only through the approved remote build-host shims. Never fall back to a local build. See org skill `honua-build-host`.
4. Commit and push completed work; keep existing branches, commits and worktrees until their retention rules permit cleanup.
5. Claim work before starting, reread the issue and current lane rulings, and release the claim after completion. See org skill `honua-dev-loop`.
6. Use a PR slot and bundle at least three issues, a plan row, or a permitted single-work reason. Current caps and exceptions come from current lane rulings.
7. Target the default branch with the repository's PR template and conventional title. Never force-push or use an admin merge.
8. Run pre-PR checks, obtain one independent review of the final head, and resolve every review thread. Merge on green required checks; arm auto-merge where enforced checks support it. See org skill `honua-pr-flow`.
9. Read failed required-check logs and fix in one push. For red trunk, fix forward or revert within the repository's current ruling deadline; see org skills `honua-red-pr` and `honua-trunk-red`.
10. Never commit secrets, deployment identifiers, private repository names or infrastructure details. Security findings belong in the private tracker. Archived repos get no issues or PRs; public instructions name org skills only.
<!-- fleet:end -->
