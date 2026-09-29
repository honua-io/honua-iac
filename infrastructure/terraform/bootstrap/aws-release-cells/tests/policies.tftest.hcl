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
  assert {
    condition     = alltrue([for policy in values(output.policies) : length(policy) <= 10240])
    error_message = "The combined inline policies must fit IAM role quotas."
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
