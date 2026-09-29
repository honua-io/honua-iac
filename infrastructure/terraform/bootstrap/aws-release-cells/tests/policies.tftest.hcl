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
