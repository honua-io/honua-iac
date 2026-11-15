mock_provider "aws" {
  override_during = plan
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/client-secret-abcdef" } }
}
mock_provider "archive" {}
mock_provider "random" {}
variables {
  member_account_id   = format("%012d", 2)
  lane_principal_arns = [format("arn:aws:iam::%s:role/GateOperator", format("%012d", 1))]
  idp_callback_urls   = ["https://gate.example.invalid/admin/auth/callback"]
}
run "confidential_authorization_code_client" {
  command = plan
  assert {
    condition     = aws_cognito_user_pool.gate.name == "honua-gate-idp" && aws_cognito_user_pool.gate.admin_create_user_config[0].allow_admin_create_user_only
    error_message = "Gate users must be administrator-created."
  }
  assert {
    condition     = aws_cognito_user_pool_client.gate.generate_secret && aws_cognito_user_pool_client.gate.allowed_oauth_flows_user_pool_client && toset(aws_cognito_user_pool_client.gate.allowed_oauth_flows) == toset(["code"]) && toset(aws_cognito_user_pool_client.gate.callback_urls) == var.idp_callback_urls
    error_message = "The confidential client must use authorization code and exact registered callbacks."
  }
  assert {
    condition     = aws_cognito_user.admin.message_action == "SUPPRESS" && aws_cognito_user_group.admin.name == "admin" && random_password.admin.length >= 32
    error_message = "The test administrator needs a generated permanent password and admin membership."
  }
  assert {
    condition     = alltrue([for secret in [aws_secretsmanager_secret.idp_client, aws_secretsmanager_secret.idp_admin] : startswith(secret.name, "honua-gate/") && secret.recovery_window_in_days >= 7])
    error_message = "Identity credentials must use recoverable gate secrets."
  }
}
run "reject_wildcard_callback" {
  command = plan
  variables { idp_callback_urls = ["https://honua-gate-*.example.invalid/admin/auth/callback"] }
  expect_failures = [var.idp_callback_urls]
}
run "reject_insecure_callback" {
  command = plan
  variables { idp_callback_urls = ["http://gate.example.invalid/admin/auth/callback"] }
  expect_failures = [var.idp_callback_urls]
}

run "default_secret_reader_is_cloudformation_only" {
  command = plan
  assert {
    condition = local.idp_client_readers == [local.service_role_arn] && alltrue([
      for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.workload_boundary.policy] : alltrue([
        anytrue([for statement in jsondecode(policy).Statement : try(statement.Sid == "DenyUnapprovedIdpReaders" && statement.Resource == aws_secretsmanager_secret.idp_client.arn && statement.Condition.ArnNotEquals["aws:PrincipalArn"] == [local.service_role_arn], false)]),
        anytrue([for statement in jsondecode(policy).Statement : try(statement.Sid == "DenyBootstrapSecretMutation" && statement.NotAction == ["secretsmanager:GetSecretValue"] && statement.Resource == aws_secretsmanager_secret.idp_client.arn, false)])
      ])
    ])
    error_message = "Only CloudFormation can read the bootstrap client secret by default; all gate mutations remain denied."
  }
}
run "exact_execution_role_can_be_registered" {
  command = plan
  variables { idp_task_execution_role_arns = ["arn:aws:iam::000000000002:role/honua-gate-install-ExecutionRole"] }
  assert {
    condition     = toset(local.idp_client_readers) == toset([local.service_role_arn, "arn:aws:iam::000000000002:role/honua-gate-install-ExecutionRole"])
    error_message = "The optional runtime exception must contain only the exact registered execution role."
  }
}
run "reject_wildcard_execution_reader" {
  command = plan
  variables { idp_task_execution_role_arns = ["arn:aws:iam::000000000002:role/honua-gate-*"] }
  expect_failures = [var.idp_task_execution_role_arns]
}
run "reject_foreign_execution_reader" {
  command = plan
  variables { idp_task_execution_role_arns = ["arn:aws:iam::000000000003:role/honua-gate-install-ExecutionRole"] }
  expect_failures = [var.idp_task_execution_role_arns]
}
