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
    condition = alltrue([for action in ["cloudwatch:PutMetricData", "cloudwatch:GetMetricData"] : anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("(?i)^${replace(replace(pattern, "*", ".*"), "?", ".")}$", action))])]) && !anytrue([
      for action in ["cloudwatch:PutMetricStream", "cloudwatch:PutDashboard", "cloudwatch:DeleteAlarms", "cloudwatch:DeleteDashboards", "cloudwatch:GetMetricStatistics", "cloudwatch:GetMetricWidgetImage", "cloudwatch:GetMetricStream", "cloudwatch:TagResource"] :
      anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("(?i)^${replace(replace(pattern, "*", ".*"), "?", ".")}$", action))])
    ])
    error_message = "PutMetricData and GetMetricData are exempt from the ownership deny; metric streams, dashboards, alarm and dashboard deletes, tagging and other metric reads stay fenced."
  }
  assert {
    condition     = length(jsonencode(jsondecode(aws_iam_policy.workload_boundary.policy))) <= 6144
    error_message = "The heartbeat exemption must keep the managed boundary within its quota."
  }
}
