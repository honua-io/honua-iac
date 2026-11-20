# Synthetic fixtures only. Gate certificate cleanup: tag-fenced by default, exact temporary IDs for untagged ones.
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

run "certificate_cleanup_is_tag_fenced_without_temporary_ids" {
  command = plan
  variables {
    gate_test_domain = "gate.example.test"
  }
  assert {
    condition     = aws_lambda_function.reaper.environment[0].variables["GATE_TEST_DOMAIN"] == "gate.example.test" && nonsensitive(aws_lambda_function.reaper.environment[0].variables["TEMPORARY_ORPHAN_CERTIFICATE_IDS"]) == ""
    error_message = "The reaper must receive the gate test domain and no temporary certificate IDs by default."
  }
  assert {
    condition = alltrue([for statement in jsondecode(aws_iam_role_policy.reaper.policy).Statement : try(
      statement.Action != "acm:DeleteCertificate" || (statement.Resource == "arn:aws:acm:us-east-1:${var.member_account_id}:certificate/*" &&
    statement.Condition.StringEquals["aws:ResourceTag/HonuaGate"] == "true"), false)])
    error_message = "Without temporary IDs, certificate deletion must require the gate ownership tag."
  }
  assert {
    condition     = !anytrue([for statement in jsondecode(aws_iam_role_policy.reaper.policy).Statement : can(regex("^acm:\\*$|^\\*$", try(one(flatten([statement.Action])), "")))])
    error_message = "The reaper must not receive wildcard ACM actions."
  }
}

run "certificate_cleanup_temporary_ids_are_exact" {
  command = plan
  variables {
    temporary_orphan_certificate_ids = ["11111111-1111-1111-1111-111111111111"]
  }
  assert {
    condition = anytrue([for statement in jsondecode(nonsensitive(aws_iam_role_policy.reaper.policy)).Statement : try(
      statement.Action == "acm:DeleteCertificate" && statement.Resource == ["arn:aws:acm:us-east-1:${var.member_account_id}:certificate/11111111-1111-1111-1111-111111111111"] &&
    !can(statement.Condition), false)])
    error_message = "Temporary certificate IDs must grant deletion of exactly those certificate ARNs."
  }
  assert {
    condition     = nonsensitive(aws_lambda_function.reaper.environment[0].variables["TEMPORARY_ORPHAN_CERTIFICATE_IDS"]) == "11111111-1111-1111-1111-111111111111"
    error_message = "The reaper must receive the temporary certificate IDs."
  }
}

run "certificate_cleanup_rejects_wildcard_ids" {
  command = plan
  variables {
    temporary_orphan_certificate_ids = ["*"]
  }
  expect_failures = [var.temporary_orphan_certificate_ids]
}
