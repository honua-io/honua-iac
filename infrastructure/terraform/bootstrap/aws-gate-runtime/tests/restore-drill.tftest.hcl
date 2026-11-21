# Synthetic fixtures only. A restore drill stack restores a gate database from an AWS Backup snapshot through the
# service role, and a drill runner task polls Backup job status; nothing else about either fence widens.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/client-secret-abcdef" } }
  mock_resource "aws_cognito_user_pool" { defaults = { id = "us-east-1_Synthetic", arn = "arn:aws:cognito-idp:us-east-1:000000000002:userpool/us-east-1_Synthetic" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::000000000002:role/mock" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
  mock_resource "aws_lambda_function" { defaults = { arn = "arn:aws:lambda:us-east-1:000000000002:function:honua-gate-reaper" } }
  mock_resource "aws_cloudwatch_event_rule" { defaults = { arn = "arn:aws:events:us-east-1:000000000002:rule/mock" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-east-1:000000000002:log-group:/aws/lambda/honua-gate-reaper" } }
}
mock_provider "archive" {}
variables {
  member_account_id       = format("%012d", 2)
  lane_principal_arns     = [format("arn:aws:iam::%s:role/GateOperator", format("%012d", 1))]
  shared_account          = true
  budget_alert_email      = "gate@example.invalid"
  protected_state_buckets = ["synthetic-state"]
  protected_ssm_paths     = ["/synthetic/gate/runtime/protected"]
}

run "service_role_restores_only_gate_snapshots" {
  command = plan
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement : try(
      statement.Sid == "DenyNonGateChanges" && contains(statement.NotAction, "rds:RestoreDBInstanceFromDBSnapshot"), false)
    ])
    error_message = "The service role must be able to restore a database whose new instance has no tags yet."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_restores.policy).Statement : try(
      statement.Sid == "RestoreGateSnapshots" && statement.Effect == "Deny" && statement.Action == "rds:RestoreDBInstanceFromDBSnapshot" &&
      statement.Resource == "arn:aws:rds:us-east-1:${var.member_account_id}:snapshot:*" &&
      statement.Condition == { StringNotEqualsIfExists = { "aws:ResourceTag/HonuaGate" = "true" } }, false)
    ])
    error_message = "A restore must be denied on any snapshot without the gate cost tag."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.cloudformation_restores.role == aws_iam_role.cloudformation.name
    error_message = "The snapshot fence must be attached to the service role."
  }
  assert {
    # The new instance stays fenced by name and request tag.
    condition     = contains(flatten([local.rds_creation_name_deny.Action]), "rds:AddTagsToResource") && contains(local.rds_creation_name_deny.NotResource, "arn:aws:rds:us-east-1:${var.member_account_id}:db:honua-gate-*")
    error_message = "Restored instances must keep the gate name and tag fences."
  }
}

run "workloads_poll_backup_jobs_but_restore_nothing_new" {
  command = plan
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(
      statement.Sid == "DenyNonGateChanges" && contains(statement.NotAction, "backup:Describe*Job") &&
      !anytrue([for action in statement.NotAction : startswith(action, "rds:Restore") || startswith(action, "backup:Start") || startswith(action, "backup:Get")]), false)
    ])
    error_message = "Workloads may read Backup job status; restores and recovery point reads stay behind the ownership tags."
  }
}

run "unmatched_read_patterns_change_no_permission" {
  command = plan
  assert {
    condition = alltrue([for pattern in ["iam:Describe*", "sns:Describe*", "sqs:Describe*", "route53:Describe*", "budgets:Get*"] :
    !contains(local.metadata_read_actions, pattern)]) && alltrue([for pattern in ["iam:Get*", "sns:Get*", "sqs:List*", "route53:Get*", "budgets:Describe*", "rds:Describe*"] : contains(local.metadata_read_actions, pattern)])
    error_message = "Only the patterns that match no API leave the metadata reads."
  }
}
