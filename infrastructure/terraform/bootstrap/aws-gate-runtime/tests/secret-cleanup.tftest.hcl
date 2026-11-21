# Synthetic fixtures only. Gate secret cleanup: stack-tag fenced, 7-day recovery window, never the IdP secret.
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
  member_account_id       = "000000000002"
  lane_principal_arns     = ["arn:aws:iam::000000000001:role/GateOperator"]
  shared_account          = true
  protected_state_buckets = ["synthetic-state"]
  protected_ssm_paths     = ["/synthetic/gate"]
  budget_alert_email      = "gate@example.invalid"
}

run "secret_cleanup_is_stack_tag_fenced_with_a_recovery_window" {
  command = plan
  assert {
    condition = length([for statement in jsondecode(aws_iam_role_policy.reaper.policy).Statement : statement
      if statement.Effect == "Allow" && contains(flatten([statement.Action]), "secretsmanager:DeleteSecret")]) == 1 && alltrue([
      for statement in jsondecode(aws_iam_role_policy.reaper.policy).Statement : try(
        statement.Effect != "Allow" || !contains(flatten([statement.Action]), "secretsmanager:DeleteSecret") || (
          statement.Condition.StringLike["aws:ResourceTag/aws:cloudformation:stack-name"] == "honua-gate-*" &&
    statement.Condition.NumericEquals["secretsmanager:RecoveryWindowInDays"] == 7), false)])
    error_message = "Secret deletion must require a honua-gate-* CloudFormation stack tag and a 7-day recovery window."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_role_policy.reaper.policy).Statement : try(
      statement.Effect == "Deny" && statement.Action == "secretsmanager:DeleteSecret" &&
    statement.Resource == "arn:aws:secretsmanager:us-east-1:${var.member_account_id}:secret:honua-gate/idp/*", false)])
    error_message = "The reaper must never delete the gate IdP secrets."
  }
  assert {
    condition     = !anytrue([for statement in jsondecode(aws_iam_role_policy.reaper.policy).Statement : can(regex("^secretsmanager:\\*$|^secretsmanager:Get|^secretsmanager:Put", try(one(flatten([statement.Action])), "")))])
    error_message = "The reaper must not read or write secret values."
  }
}
