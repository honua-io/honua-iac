###############################################################################
# Approval-receipt MAC key and the GenerateMac / VerifyMac permission split
# (honua-devops#175, gating honua-release#129).
#
# The problem this solves. honua-devops approval receipts are HMAC-symmetric:
# the verifier holds the same key the issuer signs with, so the verifier can
# forge any receipt it is willing to accept. That is fine for development and
# it is not evidence — and the day-zero lane's whole premise is
# receipts-as-evidence.
#
# The fix is not a different primitive but a different key custodian. The MAC
# key moves into KMS, where key material never leaves, and the two halves of
# the operation become two separately grantable IAM actions:
#
#   issuer principal   -> kms:GenerateMac  (and NOT kms:VerifyMac)
#   verifier principal -> kms:VerifyMac    (and NOT kms:GenerateMac)
#
# A verifier that cannot call GenerateMac cannot produce a receipt it would
# accept. That, and only that, is what makes the receipt admissible.
#
# No export path. A KMS key with key_usage = GENERATE_VERIFY_MAC has no API
# that returns key material — there is no GetPublicKey, no export, and the
# Encrypt/Decrypt/GenerateDataKey family is invalid against it. So "no
# principal exports the key" is a property of the key type, not a policy this
# root has to defend.
#
# Both halves are enforced twice: once in the identity policies attached to the
# roles, and once in the key policy, which explicitly Denies each side the
# other's action. A later identity-policy edit therefore cannot quietly re-merge
# the two capabilities.
#
# Off by default. Existing operators of this root are unaffected until they set
# enable_approval_mac_key = true and name the principals.
###############################################################################

locals {
  approval_mac_enabled = var.enable_approval_mac_key

  # A verifier list left empty means "the deployment role this root creates" —
  # the honua-devops agent that consumes an approval runs in the deployment
  # lane. The signer is never defaulted: the issuer is a release-lane identity
  # that this root does not create, and silently defaulting it would collapse
  # the separation the key exists to enforce.
  approval_verifier_role_names = length(var.approval_verifier_role_names) > 0 ? var.approval_verifier_role_names : [aws_iam_role.deployment.name]
  approval_signer_role_names   = var.approval_signer_role_names

  approval_role_arn = { for name in distinct(concat(local.approval_signer_role_names, local.approval_verifier_role_names)) :
    name => "arn:${local.partition}:iam::${local.account_id}:role/${name}"
  }

  approval_signer_role_arns   = [for name in local.approval_signer_role_names : local.approval_role_arn[name]]
  approval_verifier_role_arns = [for name in local.approval_verifier_role_names : local.approval_role_arn[name]]

  approval_mac_key_arn = one(aws_kms_key.approval_mac[*].arn)

  approval_mac_contract = {
    schema_version = "v1"
    kind           = "honua.iac.approval-mac-key"
    enabled        = local.approval_mac_enabled
    account = {
      account_id = local.account_id
      partition  = local.partition
      region     = var.aws_region
    }
    key = {
      arn           = local.approval_mac_key_arn
      alias         = one(aws_kms_alias.approval_mac[*].name)
      spec          = local.approval_mac_enabled ? "HMAC_256" : null
      usage         = local.approval_mac_enabled ? "GENERATE_VERIFY_MAC" : null
      mac_algorithm = "HMAC_SHA_256"
      # A property of the key type, not of this configuration.
      exportable = false
    }
    separation = {
      signer_role_arns    = local.approval_signer_role_arns
      signer_actions      = ["kms:GenerateMac"]
      verifier_role_arns  = local.approval_verifier_role_arns
      verifier_actions    = ["kms:VerifyMac"]
      enforced_in         = ["iam-identity-policy", "kms-key-policy"]
      verifier_can_sign   = false
      signer_can_verify   = false
      signing_mode        = "kms-mac"
      consumer_repository = "honua-devops"
    }
  }
}

# ---------------------------------------------------------------------------
# The MAC key.
#
# The two guards below are lifecycle preconditions, not `check` blocks. This
# root uses `check` elsewhere to report separation facts, but a failed check
# assertion is a WARNING: the plan still succeeds and the apply still runs. The
# properties asserted here are the security property the key exists to create,
# so they have to be a hard stop.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "approval_mac_key" {
  count = local.approval_mac_enabled ? 1 : 0

  # Account root retains administrative control, without which the key cannot be
  # managed at all. This is key ADMINISTRATION; it grants neither GenerateMac nor
  # VerifyMac, both of which are granted only by the statements below.
  statement {
    sid    = "KeyAdministration"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "IssuerMayGenerateMacOnly"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = local.approval_signer_role_arns
    }
    actions   = ["kms:GenerateMac"]
    resources = ["*"]
  }

  statement {
    sid    = "VerifierMayVerifyMacOnly"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = local.approval_verifier_role_arns
    }
    actions   = ["kms:VerifyMac"]
    resources = ["*"]
  }

  # The split, restated as a denial so that a later identity-policy edit cannot
  # re-merge the capabilities. An explicit Deny cannot be overridden by any
  # Allow, here or in an identity policy.
  statement {
    sid    = "IssuerMayNotVerify"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = local.approval_signer_role_arns
    }
    actions   = ["kms:VerifyMac"]
    resources = ["*"]
  }

  statement {
    sid    = "VerifierMayNotGenerate"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = local.approval_verifier_role_arns
    }
    actions   = ["kms:GenerateMac"]
    resources = ["*"]
  }
}

resource "aws_kms_key" "approval_mac" {
  #checkov:skip=CKV_AWS_7: Automatic key rotation is not available for KMS HMAC (GENERATE_VERIFY_MAC) keys; rotating this key is an operator-driven re-issue because it invalidates receipts signed under the previous key.
  count = local.approval_mac_enabled ? 1 : 0

  description              = "Honua approval-receipt MAC key. GenerateMac and VerifyMac are held by different principals; key material never leaves KMS."
  key_usage                = "GENERATE_VERIFY_MAC"
  customer_master_key_spec = "HMAC_256"
  deletion_window_in_days  = var.approval_mac_key_deletion_window_days
  policy                   = data.aws_iam_policy_document.approval_mac_key[0].json

  tags = merge(local.tags, {
    Purpose = "honua-approval-receipt-mac"
  })

  lifecycle {
    precondition {
      condition     = length(local.approval_signer_role_names) > 0
      error_message = "enable_approval_mac_key = true requires approval_signer_role_names. Defaulting the issuer to the verifier would recreate the forgeable-receipt problem this key exists to remove."
    }

    precondition {
      condition = length(setintersection(
        toset(local.approval_signer_role_names),
        toset(local.approval_verifier_role_names)
      )) == 0
      error_message = "A role may hold kms:GenerateMac or kms:VerifyMac on the approval key, never both: a principal holding both can forge the receipts it accepts."
    }
  }
}

resource "aws_kms_alias" "approval_mac" {
  count = local.approval_mac_enabled ? 1 : 0

  name          = "alias/${local.name}-approval-mac"
  target_key_id = aws_kms_key.approval_mac[0].key_id
}

# ---------------------------------------------------------------------------
# The two identity policies. One action each, scoped to this one key.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "approval_mac_generate" {
  count = local.approval_mac_enabled ? 1 : 0

  statement {
    sid       = "GenerateApprovalReceiptMac"
    effect    = "Allow"
    actions   = ["kms:GenerateMac"]
    resources = [aws_kms_key.approval_mac[0].arn]
  }
}

data "aws_iam_policy_document" "approval_mac_verify" {
  count = local.approval_mac_enabled ? 1 : 0

  statement {
    sid       = "VerifyApprovalReceiptMac"
    effect    = "Allow"
    actions   = ["kms:VerifyMac"]
    resources = [aws_kms_key.approval_mac[0].arn]
  }
}

resource "aws_iam_policy" "approval_mac_generate" {
  count = local.approval_mac_enabled ? 1 : 0

  name        = "${local.name}-approval-mac-generate"
  description = "kms:GenerateMac on the Honua approval-receipt MAC key. Issuers only; it deliberately carries no kms:VerifyMac."
  policy      = data.aws_iam_policy_document.approval_mac_generate[0].json
  tags        = local.tags
}

resource "aws_iam_policy" "approval_mac_verify" {
  count = local.approval_mac_enabled ? 1 : 0

  name        = "${local.name}-approval-mac-verify"
  description = "kms:VerifyMac on the Honua approval-receipt MAC key. Verifiers only; it deliberately carries no kms:GenerateMac, so a verifier cannot forge what it accepts."
  policy      = data.aws_iam_policy_document.approval_mac_verify[0].json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "approval_mac_generate" {
  for_each = local.approval_mac_enabled ? toset(local.approval_signer_role_names) : toset([])

  role       = each.value
  policy_arn = aws_iam_policy.approval_mac_generate[0].arn
}

resource "aws_iam_role_policy_attachment" "approval_mac_verify" {
  for_each = local.approval_mac_enabled ? toset(local.approval_verifier_role_names) : toset([])

  role       = each.value
  policy_arn = aws_iam_policy.approval_mac_verify[0].arn
}
