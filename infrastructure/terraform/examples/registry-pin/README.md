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

`terraform init` resolves `module.source`'s `?ref=` against a Git ref in this
repository, so the ref must exist before `init` can fetch the module. The
operator contract is to pin an immutable SemVer **tag** (e.g. `?ref=v0.1.0`) and
bump it to move to a newer release, then run `terraform init -upgrade`. See
`docs/module-versioning.md` for the release process.

Until the first SemVer tag is cut, `main.tf` pins `?ref=trunk` so the documented
operator path actually resolves today. Replace `trunk` with the SemVer tag once
it is published.

## CI validation

Because the example now pins an existing ref (`trunk`), this root is included in
the `static-validate` roots in `.github/workflows/terraform-ci.yml`. `init`
fetches the `aws-ecs` module from the Git source over the network (unlike the
other roots, which use relative paths), so this root is the one place CI
exercises the external git-source consumer contract end to end.
