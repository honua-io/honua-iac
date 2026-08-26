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

```bash
./scripts/run-aws-terraform-integration.sh
./scripts/run-azure-terraform-integration.sh
./scripts/run-eks-terraform-integration.sh
./scripts/run-aks-terraform-integration.sh
./scripts/run-k8s-terraform-integration.sh
./scripts/run-terraform-drift-detection.sh
```

There is no dedicated unit-test suite; `terraform validate` + the policy gate
are the test/lint surface.

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
.github/workflows/  terraform-ci.yml, terraform-manual-validation.yml,
                    cloud-demo-smoke.yml
```

## Conventions & Gotchas

- Every Terraform root pins `required_version` and provider versions in
  `versions.tf` — keep new roots consistent and add them to the `roots` list
  in `.github/workflows/terraform-ci.yml` so they get validated.
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

## Shared dev-environment rules (multi-agent WSL)

This machine runs many agents concurrently (**Codex + Claude**, often via agentflow with multiple tabs/agents). To prevent host lockups and lost work, every agent MUST follow these:

1. **Heavy builds/tests are throttled by a shared lock.** `dotnet` and `npm` are PATH-shimmed, so their build/test/publish/pack and ci/install/test/run-build/run-test subcommands automatically run under a global semaphore (default 1 concurrent, `HONUA_BUILD_SLOTS`). For other heavy tools, call the wrapper explicitly: `with-build-lock pytest ...`, `with-build-lock cargo build`, `with-build-lock make build`. The lock is shared across ALL of this user's processes (every Codex/Claude tab, agentflow children). Do not bypass it for compiles or test suites. Long-running servers (`dotnet run`, `npm run dev`) are intentionally NOT locked — never wrap those.

2. **Commit and push when you finish a task** so your worktree can be reclaimed. An hourly job (`honua-clean`) removes a worktree ONLY when it is clean AND fully pushed (merged, remote-gone, or idle >=2d). Dirty or unpushed worktrees are NEVER touched — but uncommitted/unpushed work blocks reclamation and is at risk if the instance is reset. Build artifacts (bin/obj and untracked node_modules) are reclaimed automatically and safely.

3. **Commit hygiene — no agent attribution.** Author every commit as the repo owner only (git identity: Mike McDougall <mike@honua.io>). Do **NOT** add any agent/tool attribution to commits: no `Co-Authored-By: Claude ...`, no `Co-Authored-By: Codex ...` (or other bot co-authors), and no "Generated with Claude Code" / "Generated with Codex" / "🤖" lines in the message or PR body. Write a plain, descriptive commit message and stop.

4. **Agents outside this WSL environment (Windows Codex/Claude, other machines).** The build lock and worktree conventions above exist only inside WSL. If you are not running inside it: work from your own checkout and never edit the WSL working trees (e.g. via `\\wsl.localhost`) — git remotes are the only shared surface; claim an issue before starting (assign yourself or leave a claiming comment), because agents that cannot see each other's worktrees cannot avoid collisions any other way; and run at most one heavy build/test at a time, avoiding overlap with active WSL builds — no semaphore protects the host across environments.
