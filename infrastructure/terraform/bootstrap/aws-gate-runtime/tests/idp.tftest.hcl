mock_provider "aws" {
  mock_resource "aws_cognito_user_pool" { defaults = { id = "us-east-1_Synthetic", arn = "arn:aws:cognito-idp:us-east-1:000000000002:userpool/us-east-1_Synthetic" } }
  override_during = plan
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
  override_resource {
    target = aws_secretsmanager_secret.idp_client
    values = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/client-secret-abcdef" }
  }
  override_resource {
    target = aws_secretsmanager_secret.idp_admin
    values = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/admin-ghijkl" }
  }
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

run "client_secret_readers_are_cloudformation_and_template_execution_roles" {
  command = plan
  assert {
    condition = alltrue([
      for pair in [[aws_iam_role_policy.cloudformation.policy, "ArnNotEquals", [local.service_role_arn]], [aws_iam_policy.workload_boundary.policy, "ArnNotLike", ["arn:aws:iam::*:role/honua-gate-*-ExecutionRole-*"]]] : alltrue([
        anytrue([for statement in jsondecode(pair[0]).Statement : try(statement.Effect == "Deny" && statement.Action == ["secretsmanager:GetSecretValue"] && statement.Resource == aws_secretsmanager_secret.idp_client.arn && keys(statement.Condition) == [pair[1]] && statement.Condition[pair[1]]["aws:PrincipalArn"] == pair[2], false)]),
        anytrue([for statement in jsondecode(pair[0]).Statement : try(statement.Effect == "Deny" && statement.Resource == aws_secretsmanager_secret.idp_admin.arn && statement.Action == ["secretsmanager:GetSecretValue"] && !can(statement.Condition), false)]),
        anytrue([for statement in jsondecode(pair[0]).Statement : try(statement.Effect == "Deny" && statement.NotAction == ["secretsmanager:GetSecretValue"] && toset(statement.Resource) == toset([aws_secretsmanager_secret.idp_client.arn, aws_secretsmanager_secret.idp_admin.arn]), false)])
      ])
    ])
    error_message = "CloudFormation reads the client secret through its own policy; the boundary admits only template execution roles; the admin secret and all mutations stay denied."
  }
}
# ArnLike wildcards match any characters within the resource segment; the regex mirrors that for the test.
run "execution_role_pattern_admits_only_template_execution_roles" {
  command = plan
  assert {
    condition = alltrue([for name in ["honua-gate-m1-20261117t1500z-ExecutionRole-AbCdEf123456", "honua-gate-a-ExecutionRole-Z"] :
    can(regex("^${replace(local.idp_execution_role_pattern, "*", ".*")}$", "arn:aws:iam::000000000002:role/${name}"))])
    error_message = "CloudFormation-named template execution roles must match the reader pattern."
  }
  assert {
    condition = !anytrue([for name in ["honua-gate-m1-BatchExecutionRole-AbC", "honua-gate-m1-TaskRole-AbC", "honua-gate-m1-RuntimeRole-AbC", "honua-gate-m1-ExecutionRole", "HonuaGateLane", "HonuaGateCloudFormation", "other-m1-ExecutionRole-AbC", "service/honua-gate-m1-ExecutionRole-AbC"] :
    can(regex("^${replace(local.idp_execution_role_pattern, "*", ".*")}$", "arn:aws:iam::000000000002:role/${name}"))])
    error_message = "Batch, task, runtime, lane, service and non-gate roles must stay outside the reader pattern."
  }
}
run "exact_execution_role_can_be_registered" {
  command = plan
  variables { idp_task_execution_role_arns = ["arn:aws:iam::000000000002:role/honua-gate-install-ExecutionRole"] }
  assert {
    condition     = local.idp_boundary_readers == [local.idp_execution_role_pattern, "arn:aws:iam::000000000002:role/honua-gate-install-ExecutionRole"] && one([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement : statement.Condition.ArnNotEquals["aws:PrincipalArn"] if try(statement.Resource == aws_secretsmanager_secret.idp_client.arn, false)]) == [local.service_role_arn]
    error_message = "An exact registration outside the pattern stays admitted by the boundary only."
  }
}
run "registrations_covered_by_the_pattern_are_dropped" {
  command = plan
  variables { idp_task_execution_role_arns = ["arn:aws:iam::000000000002:role/honua-gate-m1-20261117t1300z-ExecutionRole-AbCdEf123456", "arn:aws:iam::000000000002:role/honua-gate-m1-20261117t1500z-ExecutionRole-GhIjKl789012"] }
  assert {
    condition     = local.idp_boundary_readers == [local.idp_execution_role_pattern]
    error_message = "Per-install registrations already covered by the pattern must not grow the boundary."
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

run "shared_account_protects_both_bootstrap_secrets" {
  command = plan
  variables {
    shared_account          = true
    protected_state_buckets = ["synthetic-state"]
    protected_ssm_paths     = ["/synthetic/gate"]
    budget_alert_email      = "gate@example.invalid"
  }
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.workload_boundary.policy] : alltrue([
      anytrue([for statement in jsondecode(policy).Statement : try(statement.Effect == "Deny" && statement.NotAction == ["secretsmanager:GetSecretValue"] && toset(statement.Resource) == toset([aws_secretsmanager_secret.idp_client.arn, aws_secretsmanager_secret.idp_admin.arn]), false)]),
      anytrue([for statement in jsondecode(policy).Statement : try(statement.Effect == "Deny" && statement.Resource == aws_secretsmanager_secret.idp_admin.arn && statement.Action == ["secretsmanager:GetSecretValue"], false)])
    ])])
    error_message = "Gate identities must not read the admin password or mutate either bootstrap secret, including in shared-account mode."
  }
}
