# Synthetic fixtures only; deployment identifiers come from private SSM configuration.
mock_provider "aws" {
  mock_data "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::000000000002:oidc-provider/token.actions.githubusercontent.com" }
  }
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
  member_account_id   = format("%012d", 2)
  lane_principal_arns = [format("arn:aws:iam::%s:role/GateOperator", format("%012d", 1))]
}
override_resource {
  target = aws_iam_role.release_actions
  values = { arn = "arn:aws:iam::000000000002:role/HonuaGateReleaseActions" }
}
run "release_role_can_assume_gate_lane" {
  command = plan
  assert {
    condition = contains(jsondecode(aws_iam_role.lane.assume_role_policy).Statement[0].Principal.AWS,
    "arn:aws:iam::${var.member_account_id}:role/HonuaGateReleaseActions")
    error_message = "The release producer role must be trusted by the gate lane."
  }
}

run "release_oidc_is_exact_and_has_no_direct_workload_permissions" {
  command = plan
  assert {
    condition = jsondecode(aws_iam_role.release_actions.assume_role_policy) == {
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = { Federated = "arn:aws:iam::000000000002:oidc-provider/token.actions.githubusercontent.com" }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = { StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:honua-io/honua-release:environment:gate:ref:refs/heads/trunk"
        } }
      }]
    }
    error_message = "Trust must require the exact GitHub provider, STS audience, release repository, gate environment and trunk ref."
  }
  assert {
    condition = jsondecode(aws_iam_role_policy.release_actions.policy) == {
      Version   = "2012-10-17"
      Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Resource = aws_iam_role.lane.arn }]
    } && output.release_actions_role_arn == aws_iam_role.release_actions.arn
    error_message = "The output role must have only AssumeRole permission for HonuaGateLane."
  }
  assert {
    condition = alltrue([for subject in [
      "repo:honua-io/another-repo:environment:gate:ref:refs/heads/trunk",
      "repo:honua-io/honua-release:environment:production:ref:refs/heads/trunk",
      "repo:honua-io/honua-release:environment:gate:ref:refs/heads/feature",
      "repo:honua-io/honua-release:environment:gate:ref:refs/tags/release",
      "repo:honua-io/honua-release:environment:gate:ref:refs/pull/1/merge",
      "repo:honua-io/honua-release:environment:gate",
      "repo:honua-io/honua-release:ref:refs/heads/trunk"
    ] : jsondecode(aws_iam_role.release_actions.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] != subject])
    error_message = "Foreign repositories, environments, branches, tags, pull refs and default subjects must be rejected."
  }
}
