---
type: guide
title: "Approve provisioning with two principals"
description: "Split provision-approval receipts across a GenerateMac-only approver role and a VerifyMac-only cell role, and the owner steps to turn it on."
tags: [aws, kms, approval, provisioning]
---
# Provision approvals with two principals

honua-devops refuses a Terraform `apply` or `destroy` through
`provision_infrastructure` unless it holds a signed
`honua.devops.provision-approval/v1` receipt bound to the plan's
`plan_metadata_digest`. For that receipt to count as evidence, the party that
accepts it must not be able to produce it. This page describes the release-lane
setup that keeps the two halves on different AWS principals.

| Principal | Created by | Reached from | Can do | Cannot do |
|---|---|---|---|---|
| `honua-release-approver` | `bootstrap/aws-release-cells` (`approval.tf`) | GitHub environment `terraform-live-approval` in `honua-io/honua-release` only | `kms:GenerateMac` on the approval key | everything else (explicit `Deny NotAction kms:GenerateMac`) |
| `honua-release-cell-provision` | `bootstrap/aws-release-cells` (`main.tf`, honua-iac#208) | GitHub environment `aws-cell-provision` | `kms:VerifyMac` on the approval key, plus its cell-provisioning grants | `kms:GenerateMac` (explicit Deny in the role and in the key policy) |
| Approval MAC key (`HMAC_256`, `GENERATE_VERIFY_MAC`) | `bootstrap/aws-exec-identity` (`approval-mac.tf`) | — | — | export (KMS HMAC keys have no export API) |

The Allows live in one place. `aws-exec-identity` writes the key policy
(Allow + cross-Deny per side) and two one-action identity policies scoped to the
key ARN, and attaches them to the two roles by name. `aws-release-cells` adds
only Denies, which no later Allow can override.

## Flow

```
plan job      (role: honua-release-cell-provision)
  honua-devops provision_infrastructure action=plan        -> plan.json artifact
approve job   (role: honua-release-approver; environment terraform-live-approval,
               required reviewers)
  reviewer reads plan.json (resource changes, plan_metadata_digest)
  honua-devops --issue-provision-approval \
      --from-plan-response plan.json --action apply \
      --signing-mode kms-mac --issuer honua-release-approver  -> approval.json
apply job     (role: honua-release-cell-provision)
  honua-devops provision_infrastructure action=apply
      confirmed=true confirmation=<challenge> approvalReceiptJson=<approval.json>
  -> kms:VerifyMac, then terraform-exact-apply.sh --approved-digest
```

The approve job never holds the cell role, and the plan/apply jobs never hold
the approver role, so no single job can both mint and accept a receipt. The
GitHub environment's required reviewers are the human gate; the KMS split makes
the gate's output verifiable.

## Owner steps

These change live IAM and KMS. Agents do not run them.

1. Apply `bootstrap/aws-release-cells` (creates `honua-release-approver` and the
   provision-lane Deny). The key policy in step 2 names this role's ARN, and KMS
   rejects a key policy whose principal does not exist, so this goes first.
2. Apply `bootstrap/aws-exec-identity` with the inputs in
   `release-approval.tfvars.example`:

   ```hcl
   enable_approval_mac_key      = true
   approval_signer_role_names   = ["honua-release-approver"]
   approval_verifier_role_names = ["honua-release-cell-provision"]
   ```

   Keep `aws_region` equal to the release-cells `region` (the cell guardrails
   deny non-IAM actions in any other region), and do not use
   `environment = cert|standing|demo` (the key is tagged with it and the cell
   guardrails deny every action on resources carrying those tags).
3. In `honua-io/honua-release`, create the GitHub environment
   `terraform-live-approval` with required reviewers and no self-review.
4. Set `HONUA_DEVOPS_PROVISION_APPROVAL_ISSUER_KEY_ARNS` for both the approve
   job and the apply job to the `approval_mac_issuer_key_arns` output of
   `aws-exec-identity` (`honua-release-approver=arn:aws:kms:...`). The value is a
   locator, not a secret. Set `HONUA_DEVOPS_PROVISION_APPROVAL_SIGNING_MODE=kms-mac`
   on the apply job.

## Tests

- `bootstrap/aws-release-cells/tests/policies.tftest.hcl` — approver trust is
  exactly the `terraform-live-approval` subject, the approver is denied every
  action but `kms:GenerateMac`, the provision lane is denied `kms:GenerateMac`,
  and no lane grant carries a MAC action; sharing a lane subject or a wildcard
  subject is refused.
- `bootstrap/aws-exec-identity/tests/approval_mac.tftest.hcl` — one action per
  principal scoped to the one key, the split restated as key-policy Denies, one
  role on both sides refused, and the honua-devops env value shape.

Both run against a mocked provider. A passing test proves the policy shape, not
that the live split is configured; the live `GenerateMac`/`VerifyMac` proof is
the first governed release-cell run after the owner steps.
