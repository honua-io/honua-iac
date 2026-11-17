# Synthetic fixtures only; deployment identifiers come from private SSM configuration.
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
  member_account_id   = format("%012d", 2)
  lane_principal_arns = [format("arn:aws:iam::%s:role/GateOperator", format("%012d", 1))]
  idp_callback_urls   = ["https://gate.example.invalid/admin/auth/callback", "https://another.example.invalid/admin/auth/callback"]
}
run "callback_sync_function_is_reserved_from_templates" {
  command = plan
  assert {
    condition = alltrue([for resource in [
      local.idp_callbacks_arn, "${local.idp_callbacks_arn}:version",
      "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:${aws_cloudwatch_log_group.idp_callbacks.name}",
      "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:${aws_cloudwatch_log_group.idp_callbacks.name}:log-stream:synthetic"
    ] : anytrue([for pattern in local.protected_controls.Resource : can(regex("^${replace(pattern, "*", ".*")}$", resource))])])
    error_message = "The reaper-namespace deny must keep templates and workloads from modifying the callback function or its logs."
  }
  assert {
    condition     = aws_lambda_function.idp_callbacks.function_name == local.idp_callbacks_function && !can(regex("^${replace(local.workload_roles, "*", ".*")}$", "arn:aws:iam::${var.member_account_id}:role/${aws_iam_role.idp_callbacks.name}"))
    error_message = "The function role must sit outside the honua-gate-* roles that templates may create and modify."
  }
}
run "callback_sync_role_reads_stacks_and_writes_only_the_gate_client" {
  command = plan
  assert {
    condition = toset(flatten([for statement in jsondecode(aws_iam_role_policy.idp_callbacks.policy).Statement : statement.Action])) == toset([
      "cloudformation:ListStacks", "cloudformation:DescribeStacks", "cloudformation:ListStackResources", "cloudfront:GetDistribution",
      "cognito-idp:DescribeUserPoolClient", "cognito-idp:UpdateUserPoolClient", "logs:CreateLogStream", "logs:PutLogEvents"
    ])
    error_message = "The callback function needs stack and distribution reads, the gate client, and its own logs only."
  }
  assert {
    condition = alltrue([for statement in jsondecode(aws_iam_role_policy.idp_callbacks.policy).Statement :
      statement.Effect == "Allow" && (
        statement.Action == "cloudformation:ListStacks" ? statement.Resource == "*" :
        startswith(try(statement.Action[0], statement.Action), "cognito-idp:") ? statement.Resource == aws_cognito_user_pool.gate.arn :
        startswith(try(statement.Action[0], statement.Action), "cloudformation:") ? statement.Resource == local.stack_arn :
        statement.Action == "cloudfront:GetDistribution" ? statement.Resource == "arn:aws:cloudfront::${var.member_account_id}:distribution/*" :
        statement.Resource == "${aws_cloudwatch_log_group.idp_callbacks.arn}:*"
    )])
    error_message = "Client writes must be scoped to the gate pool and stack reads to gate stacks."
  }
  assert {
    condition     = length(jsonencode(jsondecode(aws_iam_role_policy.idp_callbacks.policy))) <= 10240
    error_message = "The callback function policy must fit the inline quota."
  }
}
run "callback_sync_configuration" {
  command = plan
  assert {
    condition     = tolist(jsondecode(aws_lambda_function.idp_callbacks.environment[0].variables["STATIC_CALLBACK_URLS"])) == sort(tolist(var.idp_callback_urls)) && aws_lambda_function.idp_callbacks.reserved_concurrent_executions == 1 && aws_lambda_function.idp_callbacks.environment[0].variables["USER_POOL_ID"] == aws_cognito_user_pool.gate.id && aws_lambda_function.idp_callbacks.environment[0].variables["SERVICE_ROLE_ARN"] == local.service_role_arn
    error_message = "The function keeps the static callbacks, targets the gate pool and runs one sync at a time."
  }
}
run "lane_may_invoke_the_sync_but_never_touch_the_client" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      one([for statement in jsondecode(policy).Statement : statement if try(statement.Sid, "") == "SyncGateCallbacks"]) == {
        Sid = "SyncGateCallbacks", Effect = "Allow", Action = "lambda:InvokeFunction", Resource = local.idp_callbacks_arn
      }
    ])
    error_message = "The lane role and its boundary must allow invoking exactly the callback function."
  }
  assert {
    condition = !anytrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] : anytrue([
      for statement in jsondecode(policy).Statement : statement.Effect == "Allow" && anytrue([for action in flatten([try(statement.Action, [])]) : startswith(action, "cognito-idp:") || startswith(action, "lambda:Update") || action == "lambda:*"])
    ])])
    error_message = "The lane must not read or update the gate client or change the function."
  }
}
run "lane_cannot_name_a_stack_into_the_secret_reader_pattern" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      one([for statement in jsondecode(policy).Statement : statement if try(statement.Sid, "") == "ReservedStackNames"]) == {
        Sid      = "ReservedStackNames", Effect = "Deny", Action = ["cloudformation:CreateStack", "cloudformation:UpdateStack"]
        Resource = "arn:aws:cloudformation:us-east-1:${var.member_account_id}:stack/*-ExecutionRole*"
      }
    ])
    error_message = "The lane must not create or update a stack whose name puts -ExecutionRole into every role name."
  }
  assert {
    condition = alltrue([for name in ["honua-gate-a-ExecutionRole-b", "honua-gate-a-ExecutionRole"] :
    can(regex("^${replace("arn:aws:cloudformation:us-east-1:${var.member_account_id}:stack/*-ExecutionRole*", "*", ".*")}$", "arn:aws:cloudformation:us-east-1:${var.member_account_id}:stack/${name}/uuid"))]) && !can(regex("^${replace("arn:aws:cloudformation:us-east-1:${var.member_account_id}:stack/*-ExecutionRole*", "*", ".*")}$", "arn:aws:cloudformation:us-east-1:${var.member_account_id}:stack/honua-gate-m1-20261117t1500z/uuid"))
    error_message = "Reserved names must be refused while ordinary gate stack names stay allowed."
  }
}
