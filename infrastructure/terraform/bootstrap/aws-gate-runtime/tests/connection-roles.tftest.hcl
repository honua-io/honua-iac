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

run "workloads_assume_only_gate_connection_roles" {
  command = plan
  assert {
    condition = [for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : statement if try(
      anytrue([for action in flatten([statement.Action]) : startswith(action, "sts:")]), false
      )] == [{
      Effect   = "Allow", Action = ["ssm:*", "sts:AssumeRole"]
      Resource = ["arn:aws:ssm:us-east-1:000000000002:parameter/honua/honua-gate-*/watchdog/*", "arn:aws:iam::000000000002:role/honua-connection-gate-*"]
    }]
    error_message = "The workload boundary must allow sts:AssumeRole only on gate test Connection roles, scoped by name with no condition."
  }
  assert {
    condition = !anytrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_role_policy.cloudformation.policy] :
      anytrue([for statement in jsondecode(policy).Statement : statement.Effect == "Allow" && anytrue([for action in flatten([try(statement.Action, [])]) : startswith(action, "sts:")])])
    ])
    error_message = "Neither the lane nor the service role may assume roles."
  }
}

run "service_role_creates_boundaried_connection_roles_only" {
  command = plan
  assert {
    condition = length([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement : statement if try(
      contains(statement.Action, "iam:CreateRole") &&
      toset(statement.Resource) == toset(["arn:aws:iam::000000000002:role/honua-gate-*", "arn:aws:iam::000000000002:role/honua-connection-gate-*"]) &&
      statement.Condition == { ArnEquals = { "iam:PermissionsBoundary" = aws_iam_policy.workload_boundary.arn } }, false
    )]) == 1
    error_message = "The service role may create gate and gate Connection roles only with the workload boundary."
  }
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.workload_boundary.policy] :
      alltrue([for statement in jsondecode(policy).Statement : !(statement.Effect == "Allow" && contains(flatten([statement.Action]), "iam:PassRole") && strcontains(jsonencode(statement.Resource), "honua-connection"))])
    ])
    error_message = "No gate principal may pass a Connection role to a service."
  }
  assert {
    condition     = !anytrue([for action in local.boundary_ownership_deny.NotAction : startswith(action, "sts:")])
    error_message = "The boundary ownership deny must keep covering sts:AssumeRole, so workloads assume only roles that carry gate ownership tags."
  }
  assert {
    condition     = !anytrue([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement : statement.Effect == "Allow" && contains(flatten([statement.Action]), "iam:DeleteRolePermissionsBoundary")])
    error_message = "The service role must not remove a permissions boundary."
  }
  assert {
    condition = length([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement : statement if try(
      contains(statement.Action, "iam:PutRolePolicy") && toset(statement.Resource) == toset(["arn:aws:iam::000000000002:role/honua-gate-*", "arn:aws:iam::000000000002:role/honua-connection-gate-*"]), false
    )]) == 1
    error_message = "The service role manages gate and gate Connection roles only."
  }
}
