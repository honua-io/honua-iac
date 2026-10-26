mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}
variables {
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
}

run "trust_and_policy" {
  command = plan
  assert {
    condition     = length(local.policy) <= 10240
    error_message = "The inline policy must fit the IAM role quota."
  }
  assert {
    condition = (
      jsondecode(aws_iam_role.reaper.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == jsondecode(jsonencode(var.oidc_subjects)) &&
      jsondecode(aws_iam_role.reaper.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com" &&
      length(jsondecode(aws_iam_role.reaper.assume_role_policy).Statement) == 1
    )
    error_message = "Trust must be exactly the honua-iac reaper/validation environments on the GitHub OIDC audience."
  }
  assert {
    condition = alltrue([
      for statement in jsondecode(local.policy).Statement :
      statement.Effect == "Deny" || alltrue([
        for action in statement.Action :
        !startswith(action, "iam:") && !startswith(action, "sts:") && !can(regex("(Create|Put|Run|Tag|Modify|Attach|Authorize)", action))
      ])
    ])
    error_message = "The reaper may only read and delete: no create/modify/tag/IAM/STS grant."
  }
  assert {
    condition = alltrue([
      for sid in ["SweepRegionsOnly", "NoRoleChainingOrIam", "NeverRetag", "ProtectStandingEnvironment", "ProtectStandingLifecycle",
      "ProtectStandingOwner", "ProtectPublicDemo", "ProtectEc2Environment", "ProtectEc2Lifecycle", "ProtectEc2Owner", "ProtectEc2Demo", "ProtectStandingNames"] :
      one([for statement in jsondecode(local.policy).Statement : statement.Effect if statement.Sid == sid]) == "Deny"
    ])
    error_message = "Every standing/demo/region/IAM protection must be an explicit Deny."
  }
  assert {
    condition = (
      contains(one([for s in jsondecode(local.policy).Statement : s if s.Sid == "ProtectStandingNames"]).Resource, "arn:aws:lambda:*:123456789012:function:honua-cert-*") &&
      one([for s in jsondecode(local.policy).Statement : s if s.Sid == "ProtectEc2Demo"]).Action == "ec2:*" &&
      one([for s in jsondecode(local.policy).Statement : s if s.Sid == "SweepRegionsOnly"]).Condition.StringNotEquals["aws:RequestedRegion"] == jsondecode(jsonencode(var.sweep_regions))
    )
    error_message = "The standing name, demo VPC and region denies must cover the reaper's delete path."
  }
  assert {
    condition     = contains(one([for s in jsondecode(local.policy).Statement : s if s.Sid == "ProveOrphaned"]).Action, "cloudtrail:LookupEvents")
    error_message = "The legacy release-cell VPC pass needs CloudTrail to attribute a VPC's creation."
  }
}

run "rejects_wildcard_or_branch_subjects" {
  command = plan
  variables {
    oidc_subjects = ["repo:honua-io/honua-iac:ref:refs/heads/trunk"]
  }
  expect_failures = [var.oidc_subjects]
}

run "rejects_foreign_repository_subject" {
  command = plan
  variables {
    oidc_subjects = ["repo:honua-io/honua-release:environment:aws-validation-reaper"]
  }
  expect_failures = [var.oidc_subjects]
}
