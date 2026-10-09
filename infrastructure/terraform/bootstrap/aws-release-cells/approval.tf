###############################################################################
# Provision-approval principals (2026.1 rc.3 fix unit C1; honua-devops#175).
#
# honua-devops refuses a Terraform apply/destroy without a signed
# honua.devops.provision-approval/v1 receipt. Under signing mode `kms-mac` the
# receipt is an HMAC computed inside KMS, and the capability is split:
#
#   honua-release-approver   (this file)      -> kms:GenerateMac on the key only
#   ${var.name}-provision    (main.tf, #208)  -> kms:VerifyMac on the key only
#
# The approver is reached only from the honua-release GitHub environment
# `terraform-live-approval`, which the operator protects with required
# reviewers. The provision lane runs the honua-devops agent that verifies the
# receipt and applies; it can never mint one.
#
# Where the Allows come from. The key, its key policy, and the two one-action
# identity policies live in bootstrap/aws-exec-identity/approval-mac.tf, which
# attaches them to these roles BY NAME. That root's key policy names these
# role ARNs, so apply this root first, then aws-exec-identity with
#   enable_approval_mac_key      = true
#   approval_signer_role_names   = ["honua-release-approver"]
#   approval_verifier_role_names = ["honua-release-cell-provision"]
# This file contributes the other half of the separation: explicit Denies that
# no later Allow can override.
#
#   approver  : Deny every action except kms:GenerateMac. The role cannot
#               verify, provision, read state, or chain into another role.
#   provision : Deny kms:GenerateMac. The agent that accepts a receipt cannot
#               produce one.
###############################################################################

locals {
  approver_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = var.approver_oidc_subject
      } }
    }]
  })

  # Least privilege by subtraction: the only action this principal can ever
  # perform is GenerateMac, and only where an Allow (the aws-exec-identity
  # managed policy, scoped to the approval key ARN) grants it.
  approver_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ApproverMayOnlyGenerateMac"
      Effect    = "Deny"
      NotAction = ["kms:GenerateMac"]
      Resource  = "*"
      }, {
      Sid      = "ApproverMayGenerateMacInCertificationRegionOnly"
      Effect   = "Deny"
      Action   = ["kms:GenerateMac"]
      Resource = "*"
      Condition = { StringNotEquals = {
        "aws:RequestedRegion" = var.region
      } }
    }]
  })

  verifier_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "VerifierMayNotGenerateMac"
      Effect   = "Deny"
      Action   = ["kms:GenerateMac"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "approver" {
  name                 = var.approver_role_name
  description          = "Issues honua-devops provision-approval receipts (kms:GenerateMac only). Assumable only from the honua-release terraform-live-approval environment."
  max_session_duration = 3600
  assume_role_policy   = local.approver_trust

  lifecycle {
    precondition {
      condition     = !contains(values(var.oidc_subjects), var.approver_oidc_subject)
      error_message = "The approver must be reached from its own protected GitHub environment, never a cell lane's subject: a lane that can approve its own plan collapses the two-principal split."
    }
    precondition {
      condition     = !contains([for lane in keys(local.lane_policies) : "${var.name}-${lane}"], var.approver_role_name)
      error_message = "The approver role must not be one of the cell lane roles."
    }
  }
}

resource "aws_iam_role_policy" "approver" {
  role   = aws_iam_role.approver.name
  name   = "approver-generate-mac-only"
  policy = local.approver_policy
}

resource "aws_iam_role_policy" "verifier" {
  role   = aws_iam_role.cell[var.approval_verifier_lane].name
  name   = "approval-verifier-no-generate-mac"
  policy = local.verifier_policy
}

output "approver_role_arn" {
  description = "Pass its NAME to aws-exec-identity approval_signer_role_names."
  value       = aws_iam_role.approver.arn
}

output "approval_principals" {
  description = "The two halves of the provision-approval split, for aws-exec-identity approval_signer_role_names / approval_verifier_role_names."
  value = {
    signer_role_names   = [aws_iam_role.approver.name]
    verifier_role_names = [aws_iam_role.cell[var.approval_verifier_lane].name]
    approver_subject    = var.approver_oidc_subject
  }
}
