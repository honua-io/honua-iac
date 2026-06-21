provider "aws" {
  region = var.region
}

# Consume the published aws-ecs module by Git source at a SemVer tag.
# This mirrors the snippet on honua.io/operations.html. Bump the ?ref= value to
# move to a newer release, then run `terraform init -upgrade`.
#
# The pinned tag must exist in the repository before `terraform init` can fetch
# the module. See docs/module-versioning.md for the release process.
module "honua" {
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/aws-ecs?ref=v0.1.0"

  environment    = var.environment
  image          = var.honua_image
  admin_password = var.honua_admin_password
  enable_postgis = true
}
