# Synthetic fixtures only; deployment identifiers come from private SSM configuration.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_organizations_account" {
    defaults = { id = "000000000002", arn = "arn:aws:organizations::000000000001:account/o-test/000000000002" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::000000000001:role/HonuaGateBudgetAction" }
  }
}
variables {
  management_account_id = format("%012d", 1)
  parent_id             = "r-test"
  account_email         = join("@", ["account", "example.invalid"])
  budget_alert_email    = join("@", ["alerts", "example.invalid"])
}
run "automatic_monthly_fence_is_member_only" {
  command = plan
  assert {
    condition     = aws_budgets_budget.gate.limit_amount == "300" && aws_budgets_budget.gate.limit_unit == "USD" && aws_budgets_budget.gate.time_unit == "MONTHLY"
    error_message = "The gate budget must be monthly USD 300."
  }
  assert {
    condition     = aws_budgets_budget_action.fence.approval_model == "AUTOMATIC" && aws_budgets_budget_action.fence.notification_type == "ACTUAL" && aws_budgets_budget_action.fence.action_threshold[0].action_threshold_value == 100
    error_message = "The fence must execute automatically at 100 percent actual cost."
  }
  assert {
    condition     = toset(one(aws_budgets_budget_action.fence.definition).scp_action_definition[0].target_ids) == toset([aws_organizations_account.gate.id]) && toset(one(aws_budgets_budget.gate.cost_filter).values) == toset([aws_organizations_account.gate.id])
    error_message = "Budget accounting and enforcement must target only the gate member."
  }
  assert {
    condition     = jsondecode(aws_organizations_policy.region.content).Statement[0].Condition.StringNotEquals["aws:RequestedRegion"] == "us-east-1" && aws_organizations_policy_attachment.region.target_id == aws_organizations_account.gate.id
    error_message = "The region fence must be attached to the gate member."
  }
  assert {
    condition     = !contains(jsondecode(aws_organizations_policy.budget_fence.content).Statement[0].NotAction, "cloudformation:CreateStack") && contains(jsondecode(aws_organizations_policy.budget_fence.content).Statement[0].NotAction, "*:Delete*")
    error_message = "Budget exhaustion must deny stack creation while retaining deletion."
  }
}
