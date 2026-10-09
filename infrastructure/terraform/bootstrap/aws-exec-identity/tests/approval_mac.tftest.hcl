# Approval-receipt MAC key: the GenerateMac / VerifyMac split for the release
# lane (2026.1 rc.3 fix unit C1, honua-devops#175).
#
# The signer is the honua-release-approver role and the verifier the release
# cell provision role, both created by bootstrap/aws-release-cells. These runs
# assert the SHAPE of what this root would write: one action per principal,
# scoped to the one key, restated as key-policy Denies, and never both actions
# on one role. Mocked provider; nothing is applied to a real account.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/terraform-test"
      user_id    = "AIDATEST"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      dns_suffix         = "amazonaws.com"
      id                 = "aws"
      partition          = "aws"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_kms_key" {
    override_during = plan
    defaults = {
      arn    = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
      key_id = "11111111-2222-3333-4444-555555555555"
    }
  }

  mock_resource "aws_iam_policy" {
    override_during = plan
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/honua-release-approval-mac"
    }
  }
}

variables {
  aws_region        = "us-east-1"
  environment       = "release"
  state_bucket_arn  = "arn:aws:s3:::honua-tfstate-test"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  oidc_provider_url = "https://token.actions.githubusercontent.com"
  oidc_subjects     = ["repo:honua-io/honua-release:environment:terraform-live"]

  enable_approval_mac_key      = true
  approval_signer_role_names   = ["honua-release-approver"]
  approval_verifier_role_names = ["honua-release-cell-provision"]
}

run "release_split_is_one_action_per_principal" {
  command = plan

  assert {
    condition = (
      aws_kms_key.approval_mac[0].key_usage == "GENERATE_VERIFY_MAC" &&
      aws_kms_key.approval_mac[0].customer_master_key_spec == "HMAC_256"
    )
    error_message = "The approval key must be a non-exportable KMS HMAC key."
  }

  assert {
    condition = (
      toset(data.aws_iam_policy_document.approval_mac_generate[0].statement[0].actions) == toset(["kms:GenerateMac"]) &&
      toset(data.aws_iam_policy_document.approval_mac_generate[0].statement[0].resources) == toset(["arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"])
    )
    error_message = "The issuer identity policy must grant kms:GenerateMac on the approval key only."
  }

  assert {
    condition = (
      toset(data.aws_iam_policy_document.approval_mac_verify[0].statement[0].actions) == toset(["kms:VerifyMac"]) &&
      toset(data.aws_iam_policy_document.approval_mac_verify[0].statement[0].resources) == toset(["arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"])
    )
    error_message = "The verifier identity policy must grant kms:VerifyMac on the approval key only."
  }

  assert {
    condition = (
      keys(aws_iam_role_policy_attachment.approval_mac_generate) == ["honua-release-approver"] &&
      keys(aws_iam_role_policy_attachment.approval_mac_verify) == ["honua-release-cell-provision"]
    )
    error_message = "GenerateMac must attach to the approver only and VerifyMac to the provision cell role only."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.approval_mac_key[0].statement :
      s.sid != "IssuerMayGenerateMacOnly" || (
        s.effect == "Allow" && toset(s.actions) == toset(["kms:GenerateMac"]) &&
        toset(tolist(s.principals)[0].identifiers) == toset(["arn:aws:iam::123456789012:role/honua-release-approver"])
      )
    ])
    error_message = "The key policy must allow GenerateMac to the approver role only."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.approval_mac_key[0].statement :
      s.sid != "VerifierMayVerifyMacOnly" || (
        s.effect == "Allow" && toset(s.actions) == toset(["kms:VerifyMac"]) &&
        toset(tolist(s.principals)[0].identifiers) == toset(["arn:aws:iam::123456789012:role/honua-release-cell-provision"])
      )
    ])
    error_message = "The key policy must allow VerifyMac to the provision cell role only."
  }

  assert {
    condition = length([
      for s in data.aws_iam_policy_document.approval_mac_key[0].statement : s
      if s.effect == "Deny" && (
        (s.sid == "IssuerMayNotVerify" && toset(s.actions) == toset(["kms:VerifyMac"])) ||
        (s.sid == "VerifierMayNotGenerate" && toset(s.actions) == toset(["kms:GenerateMac"]))
      )
    ]) == 2
    error_message = "The key policy must restate the split as explicit Denies."
  }

  assert {
    condition     = output.approval_mac_issuer_key_arns == "honua-release-approver=arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "The honua-devops issuer/verifier env value must name the approver as issuer and the key by full ARN."
  }

  assert {
    condition = (
      output.approval_mac_contract.separation.verifier_can_sign == false &&
      output.approval_mac_contract.separation.signer_can_verify == false &&
      output.approval_mac_contract.separation.signing_mode == "kms-mac"
    )
    error_message = "The approval MAC contract must record the split."
  }
}

run "refuses_one_role_on_both_sides" {
  command = plan

  variables {
    approval_signer_role_names   = ["honua-release-cell-provision"]
    approval_verifier_role_names = ["honua-release-cell-provision"]
  }

  expect_failures = [aws_kms_key.approval_mac]
}

run "refuses_a_key_without_a_signer" {
  command = plan

  variables {
    approval_signer_role_names = []
  }

  expect_failures = [aws_kms_key.approval_mac]
}

run "disabled_by_default_creates_nothing" {
  command = plan

  variables {
    enable_approval_mac_key = false
  }

  assert {
    condition     = length(aws_kms_key.approval_mac) == 0 && output.approval_mac_issuer_key_arns == null
    error_message = "Without enable_approval_mac_key the root must create no approval key."
  }
}
