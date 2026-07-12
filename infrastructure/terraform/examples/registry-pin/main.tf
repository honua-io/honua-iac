provider "aws" {
  region = var.region
}

# Consume the published aws-ecs module by Git source. This mirrors the snippet
# on honua.io/operations.html. The pinned ref MUST exist in the repository
# before `terraform init` can fetch the module.
#
# Operator guidance: pin to an immutable SemVer tag, e.g.
#   ...modules/aws-ecs?ref=v0.1.0
# and bump the ?ref= value to move to a newer release, then run
# `terraform init -upgrade`. See docs/module-versioning.md for the release
# process.
#
# Until the first SemVer release tag is published this example pins to the
# `trunk` branch so the documented operator path actually resolves and stays
# CI-validated. Replace `trunk` with the SemVer tag once it is cut.
module "honua" {
  #checkov:skip=CKV_TF_2: Pinned to the trunk branch until the first SemVer release tag is cut; the comment above documents bumping ?ref= to an immutable vX.Y.Z tag on release.
  source = "git::https://github.com/honua-io/honua-iac.git//infrastructure/terraform/modules/aws-ecs?ref=trunk"

  environment                      = var.environment
  image                            = var.honua_image
  admin_password                   = var.honua_admin_password
  connection_encryption_master_key = var.honua_connection_encryption_master_key
  enable_postgis                   = true
}
