# Synthetic fixtures only; no live AWS calls.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_cognito_user_pool" { defaults = { id = "us-east-1_Synthetic", arn = "arn:aws:cognito-idp:us-east-1:000000000002:userpool/us-east-1_Synthetic" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::000000000002:role/mock" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/other-zzzzzz" } }
  override_resource {
    target = aws_secretsmanager_secret.idp_client
    values = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/client-secret-abcdef" }
  }
  override_resource {
    target = aws_secretsmanager_secret.idp_admin
    values = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/admin-ghijkl" }
  }
  override_resource {
    target = aws_secretsmanager_secret.idp_viewer
    values = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/viewer-mnopqr" }
  }
}
mock_provider "archive" {}
mock_provider "random" {}
variables {
  member_account_id       = "000000000002"
  lane_principal_arns     = ["arn:aws:iam::000000000001:role/GateOperator"]
  shared_account          = true
  protected_state_buckets = ["synthetic-state"]
  protected_ssm_paths     = ["/synthetic/gate"]
  budget_alert_email      = "gate@example.invalid"
}

run "lane_reads_exactly_the_two_test_user_secrets" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      length([for statement in jsondecode(policy).Statement : statement if statement.Effect == "Allow" && anytrue([
        for action in flatten([statement.Action]) : startswith(lower(action), "secretsmanager:") || action == "*"
        ])]) == 1 && anytrue([for statement in jsondecode(policy).Statement : try(
        statement.Effect == "Allow" && statement.Action == "secretsmanager:GetSecretValue" && toset(statement.Resource) == toset([
          "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/admin-ghijkl",
          "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/viewer-mnopqr"
      ]), false)])
    ])
    error_message = "The lane's only Secrets Manager grant is GetSecretValue on the admin and viewer test-user secrets."
  }
}

run "lane_still_cannot_read_the_client_secret_or_any_other_secret" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      anytrue([for statement in jsondecode(policy).Statement : try(
        statement.Effect == "Deny" && toset(statement.Action) == toset(["secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue"]) &&
        toset(statement.NotResource) == toset(local.idp_test_user_secrets) &&
        !contains(statement.NotResource, aws_secretsmanager_secret.idp_client.arn) &&
      !contains(statement.NotResource, "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/other-zzzzzz"), false)])
    ])
    error_message = "The lane must stay denied every secret read except the two test users, including the IdP client secret."
  }
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      !anytrue([for statement in jsondecode(policy).Statement : try(
      statement.Effect == "Allow" && contains(flatten([statement.Resource]), aws_secretsmanager_secret.idp_client.arn), false)])
    ])
    error_message = "No lane statement may allow anything on the IdP client secret."
  }
}

run "viewer_secret_policy_admits_the_lane_and_no_other_gate_role" {
  command = plan
  assert {
    condition = alltrue([
      local.lane_role_arn == "arn:aws:iam::000000000002:role/${aws_iam_role.lane.name}",
      jsondecode(aws_secretsmanager_secret_policy.idp_viewer.policy).Statement[0].Effect == "Deny",
      jsondecode(aws_secretsmanager_secret_policy.idp_viewer.policy).Statement[0].Condition.ArnNotEquals["aws:PrincipalArn"] == local.lane_role_arn,
      toset(jsondecode(aws_secretsmanager_secret_policy.idp_viewer.policy).Statement[0].Condition.ArnLike["aws:PrincipalArn"]) == toset(["arn:aws:iam::000000000002:role/honua-gate-*", "arn:aws:iam::000000000002:role/HonuaGate*"])
    ])
    error_message = "The viewer secret's policy must exempt exactly the lane role and keep denying every other gate role."
  }
}

run "gate_workloads_still_cannot_read_the_test_user_secrets" {
  command = plan
  assert {
    condition = alltrue([
      contains(local.protected_controls.Resource, aws_secretsmanager_secret.idp_admin.arn),
      jsondecode(aws_iam_policy.workload_boundary.policy).Statement[0] == local.protected_controls,
      !contains(local.idp_client_readers, local.lane_role_arn)
    ])
    error_message = "The admin secret stays in the workload and service-role deny-all list, and the lane is not a client-secret reader."
  }
}
