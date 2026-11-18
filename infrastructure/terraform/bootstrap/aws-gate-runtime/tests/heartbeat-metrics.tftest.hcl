# Synthetic fixtures only; no live AWS calls.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/client-secret-abcdef" } }
  mock_resource "aws_cognito_user_pool" { defaults = { id = "us-east-1_Synthetic", arn = "arn:aws:cognito-idp:us-east-1:000000000002:userpool/us-east-1_Synthetic" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::000000000002:role/mock" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
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

run "workload_heartbeats_publish_metrics" {
  command = plan
  assert {
    condition = contains(local.boundary_ownership_deny.NotAction, "cloudwatch:PutMetricData") && !anytrue([
      for action in ["cloudwatch:PutMetricStream", "cloudwatch:PutDashboard", "cloudwatch:DeleteAlarms", "cloudwatch:DeleteDashboards", "cloudwatch:GetMetricData", "cloudwatch:TagResource"] :
      anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("(?i)^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "Of the non-creation CloudWatch calls only PutMetricData is exempt from the ownership deny; streams, dashboards, deletes and tags stay fenced."
  }
  assert {
    condition     = length(jsonencode(jsondecode(aws_iam_policy.workload_boundary.policy))) <= 6144
    error_message = "The heartbeat exemption must keep the managed boundary within its quota."
  }
}
