# Module Versioning

How the publishable Honua Terraform modules are versioned and consumed. This
operationalizes the decision in
[`module-publishing-decision.md`](module-publishing-decision.md).

## Distribution channel

Modules ship via **Git source at a SemVer tag**. The Honua repositories are
licensed under the Elastic License 2.0 (ELv2); the public Terraform Registry
requires an OSI-approved open-source license, so the public registry channel is
not available unless the modules are relicensed (out of scope). Git source gives
external consumers a real version pin with no extra infrastructure.

Consume a published module by Git source at a tag:

```hcl
module "honua" {
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/aws-ecs?ref=v0.1.0"
  connection_encryption_master_key = null # New deployments only; upgrades must supply the current key
  # ...module inputs...
}
```

Swap `aws-ecs` for any Tier 1 / Tier 2 module name and `v0.1.0` for the tag you
want to pin. Run `terraform init` (or `terraform init -upgrade` to move to a
newer tag).

> No SemVer tag has been cut yet, so `?ref=v0.1.0` will not resolve today. Until
> the first tag is published (see [Release process](#release-process)), pin
> `?ref=trunk` — this is what the `examples/registry-pin` consumer example does.
> Replace `trunk` with the SemVer tag once it is cut.

## Tag scheme

- Repo-wide `vMAJOR.MINOR.PATCH` tags applied at the repository root.
- All Tier 1 and Tier 2 modules are released together under a single tag.
- The module subtree at `infrastructure/terraform/modules/*` is canonical.
  Git-source consumers and the in-repo `examples/*` resolve to the same files;
  there is no separate "published copy".

## Pre-1.0 stance

The repository starts at `v0.1.0` to signal pre-1.0 interface instability.
Promotion to `v1.0.0` happens only when each Tier 1 module's input/output
contract has shipped at least one minor release without a breaking input rename
or removed output.

## Breaking-change policy

- Removing or renaming a variable or output is a major bump (or a `0.x` minor
  bump while pre-1.0).
- Adding a new optional variable with a default is a minor bump.
- Default-value changes that change apply behaviour are minor bumps and must be
  flagged in `CHANGELOG.md`.

## Deprecation runway

An input or output marked deprecated must remain functional for at least one
minor release before removal, with a `CHANGELOG.md` warning each time it ships.

## Module tiers

| Tier | Modules | Published? |
| ---- | ------- | ---------- |
| Tier 1 (runtime) | `aws-ecs`, `azure-aca`, `aws-serverless`, `azure-functions` | Yes |
| Tier 2 (add-on)  | `observability-stack` | Yes; contract may move faster |
| Tier 3 (internal) | `aws-eks`, `azure-aks`, `aws-data`, `azure-data` | No |

Tier 3 modules are internal building blocks and are not part of the published
module surface. Do not pin them by Git source for production use; depend on a
Tier 1 runtime module instead.

## Release process

1. Update `CHANGELOG.md`: move the relevant notes from `Unreleased` into a new
   `vX.Y.Z` section with one subheading per affected Tier 1 / Tier 2 module.
2. Confirm `terraform fmt -check -recursive` and `terraform validate` pass for
   every module and example root (CI `static-validate` covers this).
3. Tag the repository root: `git tag vX.Y.Z && git push origin vX.Y.Z`.
4. Publish a GitHub Release for the tag with the `CHANGELOG.md` section in the
   body and copy-paste Git-source snippets for the Tier 1 / Tier 2 modules.
