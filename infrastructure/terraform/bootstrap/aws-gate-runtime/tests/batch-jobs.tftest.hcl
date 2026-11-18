# Synthetic fixtures only; no live AWS calls.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/client-secret-abcdef" } }
  mock_resource "aws_cognito_user_pool" { defaults = { id = "us-east-1_Synthetic", arn = "arn:aws:cognito-idp:us-east-1:000000000002:userpool/us-east-1_Synthetic" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::000000000002:role/mock" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
}
mock_provider "archive" {}
variables {
  member_account_id       = "000000000002"
  lane_principal_arns     = ["arn:aws:iam::000000000001:role/GateOperator"]
  shared_account          = true
  protected_state_buckets = ["synthetic-state"]
  protected_ssm_paths     = ["/synthetic/gate"]
  budget_alert_email      = "gate@example.invalid"
}

run "workloads_stop_only_gate_jobs" {
  command = plan
  assert {
    condition = alltrue([
      for action in ["batch:ListJobs", "batch:DescribeJobs", "batch:CancelJob", "batch:TerminateJob"] : contains(local.boundary_ownership_deny.NotAction, action)
      ]) && !anytrue([
      for action in ["batch:DescribeJobDefinitions", "batch:DescribeServiceJob", "batch:TagResource"] :
      anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("(?i)^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "The workload boundary exempts exactly the job list, read, cancel and terminate calls from the ownership deny."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(
      statement.Effect == "Deny" && toset(flatten([statement.Action])) == toset(["batch:CancelJob", "batch:TerminateJob"]) && statement.Resource == "*" &&
      statement.Condition.StringNotLike["aws:ResourceTag/honua:stack"] == "honua-gate-*", false
    )])
    error_message = "Workloads may cancel or terminate only jobs tagged with a gate stack name."
  }
  assert {
    condition = !anytrue([for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement : try(
      statement.Effect == "Allow" && anytrue([for pattern in flatten([statement.Action]) : anytrue([for action in ["batch:DescribeJobs", "batch:CancelJob", "batch:TerminateJob"] : can(regex("(?i)^${replace(pattern, "*", ".*")}$", action))])]), false
    )])
    error_message = "The lane role gains neither job reads nor job stops."
  }
}

run "boundary_repeats_only_gate_prefixed_state_buckets" {
  command = plan
  variables {
    protected_state_buckets = ["synthetic-state", "honua-gate-synthetic-state"]
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(
      statement.Sid == "DenyState" && statement.Action == "s3:*" &&
      toset(statement.Resource) == toset(["arn:aws:s3:::honua-gate-synthetic-state*"]), false
      )]) && anytrue([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement : try(
      statement.Sid == "DenyState" && length(statement.Resource) == 4, false
    )])
    error_message = "The boundary must deny gate-prefixed state buckets; the service role keeps every state bucket."
  }
  assert {
    condition     = length(jsonencode(jsondecode(aws_iam_policy.workload_boundary.policy))) <= 6144
    error_message = "A gate-prefixed state bucket must still fit the managed boundary quota."
  }
}

run "boundary_omits_state_buckets_outside_the_gate_prefix" {
  command = plan
  assert {
    condition = !anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(statement.Sid == "DenyState", false)]) && anytrue([
      for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(
        statement.Sid == "DenyOtherBuckets" && statement.Action == "s3:*" && toset(statement.NotResource) == toset(["arn:aws:s3:::honua-gate-*", "arn:aws:s3:::honua-gate-*/*"]), false
    )])
    error_message = "DenyOtherBuckets already denies state buckets outside honua-gate-*, so the boundary need not repeat them."
  }
}
