# Synthetic fixtures only. A Launch Stack's customer-managed policy (BatchSubmitPolicy) takes no tags, so the
# service role may manage it by gate name only, and only gate workload roles can carry it.
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

run "stack_managed_policies_are_fenced_by_gate_name" {
  command = plan
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_workload_policies.policy).Statement : try(
      statement.Effect == "Allow" && statement.Resource == "arn:aws:iam::000000000002:policy/honua-gate-*" &&
      contains(statement.Action, "iam:CreatePolicy") && contains(statement.Action, "iam:DeletePolicy"), false
    )])
    error_message = "The service role must create and delete customer-managed policies named honua-gate-* only."
  }
  assert {
    condition = alltrue([for statement in jsondecode(aws_iam_policy.cloudformation_workload_policies.policy).Statement :
    statement.Effect == "Deny" || statement.Resource == "arn:aws:iam::000000000002:policy/honua-gate-*" && alltrue([for action in statement.Action : startswith(action, "iam:") && strcontains(action, "Polic")])])
    error_message = "The workload-policy grant must stay on gate-named policies and policy actions."
  }
  assert {
    condition = alltrue([for action in ["iam:CreatePolicy", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion"] :
    anytrue([for pattern in local.service_role_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])])
    error_message = "Untaggable gate policies need their lifecycle exempt from the service role's ownership deny, or CreatePolicy is refused."
  }
  assert {
    # Role policies and other principals' policies keep the ownership fence; workloads never manage policies.
    condition = alltrue([for action in ["iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:PutUserPolicy", "iam:AttachRolePolicy", "iam:CreatePolicy"] : alltrue([
      for deny in action == "iam:CreatePolicy" ? [local.boundary_ownership_deny] : [local.service_role_ownership_deny, local.boundary_ownership_deny] :
      !anytrue([for pattern in deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])])
    error_message = "The policy-lifecycle exemption must not cover role or user policies, nor apply to workloads."
  }
  assert {
    # The deny exemption is account-wide; this keeps the boundaries and other HonuaGate* policies unwritable.
    condition = anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_workload_policies.policy).Statement : try(
      statement.Effect == "Deny" && statement.Action == "iam:*tePolicy*" && statement.NotResource == "arn:aws:iam::000000000002:policy/honua-gate-*", false
    )])
    error_message = "Policy create, version and delete must be denied on every policy outside policy/honua-gate-*."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.cloudformation_workload_policies.role == aws_iam_role.cloudformation.name
    error_message = "The workload-policy grant must be attached to the gate CloudFormation role."
  }
}
