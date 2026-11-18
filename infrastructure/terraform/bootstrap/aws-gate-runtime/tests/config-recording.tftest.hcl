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

run "service_role_manages_the_drift_rule_only" {
  command = plan
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement :
      statement.Effect == "Allow" && contains(flatten([statement.Action]), "config:*ConfigRule*")
    ]) && contains(local.service_role_ownership_deny.NotAction, "config:*ConfigRule*")
    error_message = "CloudFormation creates, reads and deletes the stack drift rule, whose untaggable random-ID ARN no ownership tag can fence."
  }
  assert {
    condition = !anytrue([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement :
      statement.Effect == "Allow" && anytrue([for action in flatten([statement.Action]) : can(regex("(?i)recorder|deliverychannel|config:\\*$", action))])
    ])
    error_message = "The service role never manages recorders or delivery channels; the stack's function does."
  }
}

run "workloads_manage_only_recorders_and_channels" {
  command = plan
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement :
      statement.Effect == "Allow" && statement.Resource == "*" && contains(statement.Action, "config:*Recorder*") && contains(statement.Action, "config:*DeliveryChannel*")
    ]) && contains(local.boundary_ownership_deny.NotAction, "config:*Recorder*") && contains(local.boundary_ownership_deny.NotAction, "config:*DeliveryChannel*")
    error_message = "The recorder function describes, creates, starts and removes recorders and delivery channels, which have no tag context."
  }
  assert {
    condition = !anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement :
      statement.Effect == "Allow" && anytrue([for pattern in flatten([statement.Action]) : anytrue([
        for action in ["config:PutConfigRule", "config:DeleteConfigRule", "config:SelectResourceConfig", "config:GetResourceConfigHistory", "config:BatchGetResourceConfig", "config:PutConformancePack", "config:PutAggregationAuthorization"] :
        can(regex("(?i)^${replace(pattern, "*", ".*")}$", action))
      ])])
    ])
    error_message = "Workloads never manage Config rules or read recorded resource configuration."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement :
      statement.Effect == "Allow" && statement.Action == "iam:PassRole" && statement.Resource == local.workload_roles && contains(statement.Condition.StringEquals["iam:PassedToService"], "config.amazonaws.com")
    ])
    error_message = "The recorder function passes only a gate role to AWS Config."
  }
  assert {
    condition     = length(jsonencode(jsondecode(aws_iam_policy.workload_boundary.policy))) <= 6144 && length(jsonencode(jsondecode(aws_iam_role_policy.cloudformation.policy))) <= 10240
    error_message = "Config recording must keep the boundary and the service role within their quotas."
  }
}
