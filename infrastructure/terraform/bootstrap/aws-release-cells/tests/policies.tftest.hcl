mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}
variables {
  oidc_provider_arn     = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  mirror_repository_arn = "arn:aws:ecr:us-east-1:123456789012:repository/honua-server"
}
run "policies" {
  command = plan
  variables {
    runtime_bedrock_model_arns = [
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-5-20250929-v1:0",
      "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0",
      "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0",
      "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0"
    ]
    enable_workload_role_passing = true
    workload_vpc_arns            = ["arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0"]
  }
  override_data {
    target = data.aws_vpc.workload["arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0"]
    values = { tags = { Owner = "release-cell", ValidationRunId = "gha-208-aws-serverless", Environment = "test" } }
  }
  assert {
    condition     = length(local.guardrail_policy) <= 6144
    error_message = "Shared guardrails must fit the managed policy quota."
  }
  assert {
    condition     = alltrue([for policy in values(local.grant_policies) : length(policy) <= 10240])
    error_message = "The inline grant policies must fit IAM role quotas."
  }
  assert {
    condition     = length(output.runtime_boundary) <= 6144
    error_message = "The workload boundary must fit the IAM managed policy quota."
  }
  assert {
    condition     = alltrue([for lane, role in aws_iam_role.cell : jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == var.oidc_subjects[lane]])
    error_message = "Lane trust must use exact distinct OIDC subjects."
  }
}
run "reject_shared_trust" {
  command = plan
  variables {
    oidc_subjects = {
      provision = "repo:honua-io/honua-release:ref:refs/heads/trunk"
      mirror    = "repo:honua-io/honua-release:ref:refs/heads/trunk"
      reaper    = "repo:honua-io/honua-release:ref:refs/heads/trunk"
    }
  }
  expect_failures = [var.oidc_subjects]
}

run "passrole_is_disabled_before_inventory" {
  command = plan
  assert {
    condition     = alltrue([for statement in jsondecode(output.policies.provision).Statement : statement.Sid != "PassCellRoles"])
    error_message = "A fresh bootstrap must not delegate an unverified legacy role."
  }
}

run "reject_standing_network" {
  command = plan
  variables {
    workload_vpc_arns = ["arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0"]
  }
  override_data {
    target = data.aws_vpc.workload["arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0"]
    values = { tags = { Owner = "release-cell", ValidationRunId = "gha-208-aws-serverless", Environment = "cert" } }
  }
  expect_failures = [aws_iam_policy.workload_boundary]
}

run "reject_wildcard_bedrock_boundary" {
  command = plan
  variables {
    runtime_bedrock_model_arns = ["arn:aws:bedrock:us-east-1::foundation-model/*"]
  }
  expect_failures = [var.runtime_bedrock_model_arns]
}

run "approver_is_a_separate_generate_mac_only_principal" {
  command = plan
  assert {
    condition = (
      jsondecode(aws_iam_role.approver.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:honua-io/honua-release:environment:terraform-live-approval" &&
      jsondecode(aws_iam_role.approver.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com" &&
      length(jsondecode(aws_iam_role.approver.assume_role_policy).Statement) == 1
    )
    error_message = "The approver must be assumable only from the protected terraform-live-approval environment."
  }
  assert {
    condition     = aws_iam_role.approver.name == "honua-release-approver" && !contains([for role in aws_iam_role.cell : role.name], aws_iam_role.approver.name)
    error_message = "The approver must be its own role, not a cell lane."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.approver.policy).Statement :
    s.Effect == "Deny" && s.NotAction == ["kms:GenerateMac"] && s.Resource == "*" && !can(s.Condition)])
    error_message = "The approver must be denied every action except kms:GenerateMac."
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.approver.policy).Statement : s.Effect == "Deny"])
    error_message = "This root grants the approver nothing; the GenerateMac Allow is scoped to the key by aws-exec-identity."
  }
  assert {
    condition = (
      aws_iam_role_policy.verifier.role == "honua-release-cell-provision" &&
      anytrue([for s in jsondecode(aws_iam_role_policy.verifier.policy).Statement : s.Effect == "Deny" && s.Action == ["kms:GenerateMac"]])
    )
    error_message = "The provision lane verifies receipts and must be denied kms:GenerateMac."
  }
  assert {
    condition     = alltrue([for lane, policy in local.grant_policies : !strcontains(policy, "kms:GenerateMac") && !strcontains(policy, "kms:VerifyMac")])
    error_message = "No cell lane grant may carry a MAC action; the verifier's VerifyMac comes only from the approval key's own policy."
  }
}

run "reject_approver_sharing_a_lane_subject" {
  command = plan
  variables {
    approver_oidc_subject = "repo:honua-io/honua-release:environment:aws-cell-provision"
  }
  expect_failures = [aws_iam_role.approver]
}

run "reject_wildcard_approver_subject" {
  command = plan
  variables {
    approver_oidc_subject = "repo:honua-io/honua-release:*"
  }
  expect_failures = [var.approver_oidc_subject]
}
