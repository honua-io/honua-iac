provider "aws" {
  region = var.region
}

# Consume the published aws-ecs module by Git source. This mirrors the snippet
# on honua.io/operations.html. The pinned ref MUST exist in the repository
# before `terraform init` can fetch the module.
#
# Operator guidance: pin to an immutable SemVer tag, e.g.
#   ...modules/aws-ecs?ref=v0.2.0
# and bump the ?ref= value to move to a newer release, then run
# `terraform init -upgrade`. See docs/module-versioning.md for the release
# process. CI validates this consumer against the commit under test by
# rewriting the ref, so the contract is checked before a tag exists.
module "honua" {
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/aws-ecs?ref=v0.2.0"

  environment                      = var.environment
  image                            = var.honua_image
  admin_password                   = var.honua_admin_password
  connection_encryption_master_key = var.honua_connection_encryption_master_key
  enable_postgis                   = true
}
