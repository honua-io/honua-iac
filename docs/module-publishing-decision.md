---
type: concept
title: "Why modules are not on the Terraform Registry"
description: "The recorded decision: modules are distributed by Git source at a SemVer tag because the Elastic License 2.0 blocks the public registry, and relicensing is out of scope."
resource: "https://github.com/honua-io/honua-iac/tree/trunk/infrastructure/terraform/modules"
tags: [decision, licensing, registry]
---
# Module Publishing Decision

Tracks the evaluation requested in honua-io/honua-terraform#10 (now
honua-io/honua-iac): should the Terraform modules under
`infrastructure/terraform/modules/` be published to a registry, and if so, how.

This document is the recorded decision.

## Status: decided and adopted (honua-io/honua-iac#39)

The recommendation below is **adopted**. Modules are distributed via **Git
source at a SemVer tag**, not the public Terraform Registry. The public registry
is blocked by the Elastic License 2.0 (see
[Why not the public Terraform Registry](#why-not-the-public-terraform-registry));
publishing there would require relicensing, which is out of scope.

The `source = "honua-io/honua/aws"` public-registry snippet on
`honua.io/operations.html` returns 404 because no such registry module exists.
That snippet is replaced with the resolvable Git-source form documented in
[`module-versioning.md`](module-versioning.md). The consumable form is:

```hcl
module "honua" {
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/aws-ecs?ref=trunk"
  connection_encryption_master_key = null # New deployments only; upgrades must supply the current key
  # ...module inputs...
}
```

Operational details (tag scheme, pre-1.0 stance, breaking-change policy, release
process) live in [`module-versioning.md`](module-versioning.md). The
`CHANGELOG.md` at the repo root tracks per-release notes. The
`infrastructure/terraform/examples/registry-pin/` example exercises the
Git-source consumer contract end-to-end.

Remaining manual step: cut and push the first `v0.1.0` tag and publish the
matching GitHub Release. Tagging requires push access to the repository and is
performed by a maintainer; see the release process in `module-versioning.md`.

## Recommendation

**Publish via Git source with repo-wide SemVer tags. Do not publish to the
public Terraform Registry.**

Operators continue to consume modules via the in-repo `examples/*` stacks using
relative paths. External consumers who want a versioned pin reference each
publish-candidate module by Git source at a tag, for example:

```hcl
module "honua" {
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/aws-ecs?ref=trunk"
  connection_encryption_master_key = null # New deployments only; upgrades must supply the current key
  # ...
}
```

### Why not the public Terraform Registry

The repository is licensed under Elastic License 2.0 (ELv2). The public
Terraform Registry requires an OSI-approved open-source license, so the public
registry channel is blocked unless the modules are relicensed. Relicensing is
out of scope for this ticket.

### Why not a private Terraform Registry

A private Terraform Registry (Terraform Cloud / Enterprise) adds infrastructure
ownership, identity wiring, and recurring cost. No external consumer is
confirmed today that needs registry-style discovery UX. Git source covers the
"pin to a version" requirement without that overhead and can be revisited if a
consumer materialises.

### Why Git source is sufficient

- Works against any Terraform >= 1.5 with no additional infrastructure.
- Preserves the existing in-repo consumption pattern - examples and validation
  flows keep using relative paths.
- Each Tier 1 / Tier 2 module subtree is self-contained at a tag (no cross-
  module local references), so subdirectory pinning resolves cleanly.
- Consumers get a real SemVer pin and can `terraform init -upgrade` against tag
  refs in CI.

## Module inventory and tier classification

Source: enumeration of `infrastructure/terraform/modules/` plus inspection of
each module's `README.md`, `versions.tf`, and `outputs.tf`.

### Tier 1 - publish-candidate (externally supported runtime surface)

| Module             | What it deploys                                                  | Notes                                                                              |
| ------------------ | ---------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `aws-ecs`          | ECS/Fargate + ALB + RDS + optional Redis                          | Full README, canary support, `control_plane_*` outputs.                            |
| `azure-aca`        | Azure Container Apps + PG Flexible + Key Vault + optional Redis  | Full README, `control_plane_*` outputs.                                            |
| `aws-serverless`   | Lambda container image + API Gateway HTTP API + RDS              | Full README, documented Lambda alias semantics, `control_plane_*` outputs.        |
| `azure-functions`  | Azure Functions custom container + PG Flexible + optional Redis  | Full README, slot-rollout semantics, `control_plane_*` outputs.                    |

### Tier 2 - optional add-on (publish-candidate, contract may move faster)

| Module                | What it deploys                  | Notes                                                                                                              |
| --------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `observability-stack` | Prometheus + Grafana via Helm    | README already describes it as "Optional Add-On". Bundles `assets/` data files; expect more frequent minor bumps. |

### Tier 3 - internal-only (do not publish)

| Module        | Why internal                                                                                                              |
| ------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `aws-eks`     | README states the module is for integration validation flows; intentionally minimal. Stabilising as a public contract is more work than the current value justifies. |
| `azure-aks`   | Same scope as `aws-eks`.                                                                                                   |
| `aws-data`    | No README, no documented contract. Building block for `examples/aws-data`. Consumers should depend on Tier 1 runtime modules instead. |
| `azure-data`  | Same scope as `aws-data`.                                                                                                  |

If the publish decision is approved, each Tier 3 module's README (or a new stub
for the data modules) gets a single sentence stating
"internal-only; not part of the published module surface" so we do not
accidentally invite external dependencies on it.

## Versioning and release approach

- **Tag scheme**: repo-wide `vMAJOR.MINOR.PATCH` applied at the repo root. All
  Tier 1 + Tier 2 modules are released together under that tag.
- **Pre-1.0 stance**: start at `v0.1.0` to signal pre-1.0 interface
  instability. Promote to `v1.0.0` only when each Tier 1 module's input/output
  contract has at least one minor release without a breaking input rename or
  removed output.
- **Breaking-change policy**:
  - Removing or renaming a variable or output is a major bump (or a `0.x` minor
    bump while pre-1.0).
  - Adding a new optional variable with a default is a minor bump.
  - Default-value changes that change apply behaviour are minor bumps and must
    be flagged in the CHANGELOG.
- **Deprecation runway**: an input or output marked deprecated must remain
  functional for at least one minor release before removal, with a CHANGELOG
  warning each time it ships.
- **CHANGELOG**: a single top-level `CHANGELOG.md`, one section per release,
  one subheading per Tier 1 / Tier 2 module per release. This keeps churn
  visible without per-module CHANGELOGs (which would duplicate writing effort).
- **Source of truth**: the modules under
  `infrastructure/terraform/modules/*` remain canonical. Git-source consumers
  and in-repo `examples/*` resolve to the same files; we do not maintain a
  separate "published copy".

## Impact on examples, validation, CI, and local development

### Examples (`infrastructure/terraform/examples/*`)

- Zero change. They keep using `source = "../../modules/<name>"`.
- Adds one new example, `examples/registry-pin/` (or similar), that consumes a
  single Tier 1 module via Git source at the latest tag. It exercises the
  consumer contract end-to-end without forking the operator examples.

### Validation flows (`infrastructure/terraform/validation/*` and
`terraform-manual-validation.yml`)

- Zero change. Maintainer-only validation continues to use relative paths and
  should not pay the cost of the registry-pin path.

### CI (`.github/workflows/terraform-ci.yml`)

- No restructuring. The existing static-validate job already iterates over all
  module roots and example roots; the new `examples/registry-pin/` root is
  added to the list once it lands.
- A new tag-triggered workflow (`terraform-release.yml`) runs on `v*` tags,
  re-runs the static-validate matrix against Tier 1/Tier 2 module roots,
  publishes a GitHub Release with the CHANGELOG section, and optionally posts
  copy-paste source snippets in the release body.

### Local operator development

- **Operators using `examples/*`**: zero change. They keep cloning the repo
  and running `terraform -chdir=infrastructure/terraform/examples/<stack>`.
- **Operators templating their own root module**: switch the `source = ` line
  to the Git-source form. The README snippet in each Tier 1 / Tier 2 module
  becomes the copy-paste path.
- Provider version constraints (`required_version = ">= 1.5, < 2.0"` and the
  AWS / azurerm constraints in each module's `versions.tf`) stay as they are.
- License notice: ELv2 still applies to consumers who pull modules via Git
  source. The operator-deployment guide will call this out explicitly when the
  publishing rollout ships.

## What followed the decision

The follow-up work the decision called for has mostly landed on `trunk`:

- Versioning policy, breaking-change rules and deprecation runway are in
  [How modules are versioned and consumed](module-versioning.md), with a
  repository `CHANGELOG.md`.
- `examples/registry-pin/` consumes a Tier 1 module by Git source at a tag.
- Each Tier 1 module README and the `observability-stack` README open with a
  "Pin to a release" section; Tier 3 module READMEs carry the internal-only
  notice.
- [Deploy Honua as a platform operator](operator-deployment.md) has a
  "Consuming modules at a pinned version" section with the ELv2 callout.
- `v0.1.0` is tagged. Releases are still cut by hand; a tag-triggered release
  workflow has not been added.

## Risks accepted

- **Repo-wide tagging couples release cadence across Tier 1 modules.** A fix
  in `azure-aca` alone still forces a new tag for everyone. We prefer the
  simpler scheme over per-module tags.
- **No provenance / signing today.** Consumers must trust the upstream tag or
  vendor a copy. Signed tags are deferred; not blocking for `v0.1.0`.
- **Tier 3 cut is deliberate.** If a consumer later wants `aws-eks`,
  `azure-aks`, `aws-data`, or `azure-data` externally, we promote them in a
  future ticket - not retroactively in `v0.1.0`.
