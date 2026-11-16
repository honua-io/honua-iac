# Synthetic fixtures only. IAM and KMS reject aws:-prefixed tags, so a gate stack's roles and keys are owned
# through the stack's required HonuaGate=true tag; everything else may also use the CloudFormation stack tag.
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

run "roles_and_keys_are_owned_through_the_required_stack_tag" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_policy.workload_boundary.policy, aws_iam_role_policy.cloudformation.policy] : anytrue([
      # The service role also spares CloudFormation's own creation tags (creation-tags.tftest.hcl).
      for statement in jsondecode(policy).Statement : try(statement.Sid == "DenyNonGateChanges" && statement.Effect == "Deny" && jsonencode(statement.Condition) == (
        policy == aws_iam_role_policy.cloudformation.policy ? jsonencode({
          StringNotLikeIfExists   = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*", "aws:RequestTag/aws:cloudformation:stack-name" = "honua-gate-*" }
          StringNotEqualsIfExists = { "aws:ResourceTag/HonuaGate" = "true" }
          }) : jsonencode({
          StringNotLikeIfExists   = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" }
          StringNotEqualsIfExists = { "aws:ResourceTag/HonuaGate" = "true" }
      })), false)
    ])])
    error_message = "The ownership deny must spare resources carrying either the gate stack-name tag or the required HonuaGate tag."
  }
  assert {
    # The tag is only trustworthy while every gate stack must carry it.
    condition = anytrue([for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement : try(
      statement.Sid == "RequireGateCostTag" && statement.Condition.StringNotEqualsIfExists["aws:RequestTag/HonuaGate"] == "true", false
    )])
    error_message = "Gate stacks must be created and updated with HonuaGate=true."
  }
  assert {
    condition = alltrue([for action in ["kms:TagResource", "iam:TagRole", "kms:PutKeyPolicy", "iam:PutRolePolicy"] : alltrue([
      for deny in [local.boundary_ownership_deny, local.service_role_ownership_deny] : !anytrue([for pattern in deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])])
    error_message = "Tagging and policy changes on roles and keys must stay behind the ownership deny."
  }
}
