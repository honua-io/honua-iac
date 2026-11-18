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

run "lane_can_inspect_resource_ownership" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      anytrue([for statement in jsondecode(policy).Statement : try(
        statement.Effect == "Allow" && statement.Action == "ec2:Describe*" && statement.Resource == "*", false
        )]) && anytrue([for statement in jsondecode(policy).Statement : try(
        statement.Effect == "Allow" && statement.Action == "kms:ListResourceTags" &&
        statement.Resource == "arn:aws:kms:us-east-1:000000000002:key/*", false
      )])
    ])
    error_message = "Lane permissions and their boundary must both allow EC2 inspection and KMS key-tag reads in the gate account and region."
  }
}

run "lane_runtime_inspection_is_read_only_and_gate_scoped" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      length([for statement in jsondecode(policy).Statement : statement if try(
        statement.Sid == "InspectGateRuntime" && statement.Effect == "Allow" && !can(statement.Condition) &&
        toset(statement.Action) == toset(["ecs:DescribeTasks", "logs:DescribeLogStreams", "logs:FilterLogEvents", "logs:GetLogEvents"]) &&
        toset(statement.Resource) == toset([
          "arn:aws:ecs:us-east-1:000000000002:task/honua-gate-*-Cluster-*/*",
          "arn:aws:logs:us-east-1:000000000002:log-group:/honua/honua-gate-*",
          "arn:aws:logs:us-east-1:000000000002:log-group:aws-waf-logs-honua-gate-*",
          "arn:aws:logs:us-east-1:000000000002:log-group:/aws/vendedlogs/honua/honua-gate-*",
          "arn:aws:logs:us-east-1:000000000002:log-group:/aws/rds/instance/honua-gate-*"
        ]), false
        )]) == 1 && length([for statement in jsondecode(policy).Statement : statement if try(
        statement.Sid == "ListGateTasks" && statement.Effect == "Allow" && statement.Action == "ecs:ListTasks" && statement.Resource == "*" &&
        statement.Condition.ArnLike["ecs:cluster"] == "arn:aws:ecs:us-east-1:000000000002:cluster/honua-gate-*-Cluster-*", false
      )]) == 1
    ])
    error_message = "Both lane policies must allow only read-only task and log inspection, scoped to gate-named clusters and log groups in the gate account."
  }
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      !anytrue([for statement in jsondecode(policy).Statement : statement.Effect == "Allow" && anytrue([
        for action in flatten([statement.Action]) : contains(["ecs:DescribeTaskDefinition", "ecs:ExecuteCommand", "logs:StartQuery", "secretsmanager:GetSecretValue", "wafv2:GetLoggingConfiguration"], action) || endswith(action, ":*")
      ])])
    ])
    error_message = "Lane runtime inspection must not grant unscoped task-definition reads, command execution, account-wide log queries, secret reads or service wildcards."
  }
}

run "lane_inspection_cannot_read_ec2_content" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      alltrue([for action in ["ec2:DescribeInstanceAttribute", "ec2:DescribeKeyPairs", "ec2:DescribeLaunchTemplateVersions", "ec2:DescribeVpnConnections"] :
        anytrue([for statement in jsondecode(policy).Statement : try(
          statement.Effect == "Deny" && statement.Resource == "*" &&
          contains(statement.Action, action) && !can(statement.Condition), false
        )])
      ])
    ])
    error_message = "Both lane policies must deny EC2 content reads unconditionally, including resources with gate ownership tags."
  }
}
