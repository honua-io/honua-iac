# Synthetic fixtures only; deployment identifiers come from private SSM configuration.
mock_provider "aws" {
  override_during = plan
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
run "lane_is_stack_only_and_workloads_are_bounded" {
  command = plan
  assert {
    condition     = jsondecode(aws_iam_role_policy.lane.policy).Statement[0].Resource == format("arn:aws:cloudformation:us-east-1:%s:stack/honua-gate-*/*", format("%012d", 2)) && jsondecode(aws_iam_role_policy.lane.policy).Statement[0].Condition.StringEquals["cloudformation:RoleArn"] == local.service_role_arn
    error_message = "Lane mutations require a gate stack name and the single service role."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.cloudformation.policy).Statement[2].Condition.ArnEquals["iam:PermissionsBoundary"] == aws_iam_policy.workload_boundary.arn
    error_message = "CloudFormation must enforce the workload boundary at role creation."
  }
  assert {
    condition     = jsondecode(aws_iam_policy.workload_boundary.policy).Statement[0].Effect == "Deny" && jsondecode(aws_iam_role_policy.cloudformation.policy).Statement[0] == jsondecode(aws_iam_policy.workload_boundary.policy).Statement[0]
    error_message = "Templates and workload code must be unable to modify the reaper."
  }
  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.cloudformation.policy).Statement[5].Condition.StringEquals["iam:AWSServiceName"], "ecs.application-autoscaling.amazonaws.com")
    error_message = "A fresh account must permit creation of the ECS autoscaling service-linked role."
  }
  assert {
    condition     = aws_cloudwatch_event_rule.nightly.schedule_expression == "cron(0 3 * * ? *)" && aws_lambda_function.reaper.environment[0].variables["SERVICE_ROLE_ARN"] == local.service_role_arn
    error_message = "The nightly reaper must delete through the same service role."
  }
}
run "wildcard_trust_is_rejected" {
  command = plan
  variables { lane_principal_arns = [format("arn:aws:iam::%s:role/*", format("%012d", 1))] }
  expect_failures = [var.lane_principal_arns]
}
