# Git-source pinned example

Demonstrates consuming a published Honua module by **Git source at a SemVer
tag** — the distribution channel chosen in
[`docs/module-publishing-decision.md`](../../../../docs/module-publishing-decision.md).
This is the form the `honua.io` site snippet points at, instead of the public
Terraform Registry (which is unavailable under the Elastic License 2.0).

This example is intentionally minimal: it pins the `aws-ecs` module at a tag and
passes the required inputs. It is the external-consumer contract, kept separate
from the operator `examples/aws` stack (which uses a relative `source` path).

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set honua_image and honua_admin_password
terraform -chdir=infrastructure/terraform/examples/registry-pin init
terraform -chdir=infrastructure/terraform/examples/registry-pin plan
```

## Pinning to a release

The `module.source` in `main.tf` ends with `?ref=v0.1.0`. `terraform init`
resolves that against a Git tag in this repository. The tag must exist before
`init` can fetch the module — until the first `v0.1.0` tag is cut and pushed,
`init` against the pinned `ref` will fail with a "reference not found" error.
That is expected pre-release; see `docs/module-versioning.md` for the release
process.

To move to a newer release, bump the `?ref=` value and run
`terraform init -upgrade`.

## Why this is not in the blocking CI roots list

Because the pinned `ref` may not exist yet (tag-availability lag), this root is
deliberately kept out of the `static-validate` roots in
`.github/workflows/terraform-ci.yml`. The module subtree it consumes
(`modules/aws-ecs`) is already validated there directly.
