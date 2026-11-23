# Synthetic fixtures only; deployment identifiers come from private SSM configuration.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_cognito_user_pool" { defaults = { id = "us-east-1_Synthetic", arn = "arn:aws:cognito-idp:us-east-1:000000000002:userpool/us-east-1_Synthetic" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-east-1:000000000002:log-group:/aws/lambda/honua-gate-reaper-callbacks" } }
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/synthetic-abcdef" } }
}
mock_provider "archive" {}
mock_provider "random" {}
variables {
  member_account_id   = format("%012d", 2)
  lane_principal_arns = [format("arn:aws:iam::%s:role/GateOperator", format("%012d", 1))]
  idp_callback_urls   = ["https://localhost/admin/auth/callback", "https://gate.example.invalid/admin/auth/callback"]
}
run "lane_can_only_invoke_the_protected_callback_sync" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] : length([
      for statement in jsondecode(policy).Statement : statement if contains(flatten([try(statement.Action, [])]), "lambda:InvokeFunction") && statement.Effect == "Allow"
    ]) == 1 && anytrue([for statement in jsondecode(policy).Statement : try(statement.Sid == "SyncIdpCallbacks" && statement.Resource == "arn:aws:lambda:us-east-1:000000000002:function:${aws_lambda_function.idp_callbacks.function_name}", false)])])
    error_message = "The lane may invoke only the callback sync function."
  }
  assert {
    condition = !anytrue([for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement : anytrue([
      for action in flatten([try(statement.Action, [])]) : startswith(lower(action), "cognito-idp:") && statement.Effect == "Allow"
    ])])
    error_message = "The lane must not update or describe the IdP client itself (DescribeUserPoolClient returns the secret)."
  }
  assert {
    condition     = startswith(aws_lambda_function.idp_callbacks.function_name, "honua-gate-reaper") && startswith(aws_cloudwatch_log_group.idp_callbacks.name, "/aws/lambda/honua-gate-reaper") && anytrue([for resource in local.protected_controls.Resource : endswith(resource, ":function:honua-gate-reaper*")])
    error_message = "The callback sync function and its logs must sit in the protected reaper namespace that stacks cannot modify."
  }
  assert {
    condition     = !startswith(aws_iam_role.idp_callbacks.name, "honua-gate-")
    error_message = "The callback sync role must be outside the honua-gate-* namespace the CloudFormation role manages."
  }
}
run "callback_sync_role_is_scoped" {
  command = plan
  assert {
    condition = jsondecode(aws_iam_role_policy.idp_callbacks.policy).Statement == [
      { Effect = "Allow", Action = "cloudformation:ListStacks", Resource = "*" },
      { Effect = "Allow", Action = ["cloudformation:DescribeStacks", "cloudformation:ListStackResources"], Resource = local.stack_arn },
      { Effect = "Allow", Action = "cloudfront:GetDistribution", Resource = "arn:aws:cloudfront::000000000002:distribution/*" },
      { Effect = "Allow", Action = ["cognito-idp:DescribeUserPoolClient", "cognito-idp:UpdateUserPoolClient"], Resource = aws_cognito_user_pool.gate.arn },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.idp_callbacks.arn}:*" },
    ]
    error_message = "The sync role may read gate stacks and this account's distributions and update only the gate pool's clients."
  }
  assert {
    condition     = aws_lambda_function.idp_callbacks.reserved_concurrent_executions == 1 && aws_lambda_function.idp_callbacks.environment[0].variables.STATIC_CALLBACKS == "https://gate.example.invalid/admin/auth/callback,https://localhost/admin/auth/callback"
    error_message = "One sync at a time, with the static callbacks always kept."
  }
}
run "lane_cannot_name_a_stack_like_an_execution_role" {
  command = plan
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement : try(
      statement.Effect == "Deny" && contains(statement.Action, "cloudformation:CreateStack") && statement.Resource == "arn:aws:cloudformation:us-east-1:000000000002:stack/*ExecutionRole*/*", false
    )])
    error_message = "A stack named like an execution role would make every generated role match the secret-reader pattern."
  }
}
run "reject_more_than_twenty_static_callbacks" {
  command = plan
  variables { idp_callback_urls = [for index in range(21) : format("https://gate-%02d.example.invalid/admin/auth/callback", index)] }
  expect_failures = [var.idp_callback_urls]
}
