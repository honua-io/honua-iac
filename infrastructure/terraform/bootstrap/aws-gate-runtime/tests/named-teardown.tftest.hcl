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

run "named_teardown_is_scoped_to_the_service_role" {
  command = plan
  assert {
    condition = alltrue([for action in ["events:RemoveTargets", "events:DeleteRule", "kms:DeleteAlias"] :
      contains(local.service_role_ownership_deny.NotAction, action) &&
      !anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("(?i)^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "Only the service role may bypass ownership tags for the three named teardown actions."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : try(
      statement.Sid == "NamedTeardownFence" && statement.Effect == "Deny" &&
      toset(statement.Action) == toset(["events:RemoveTargets", "events:DeleteRule", "kms:DeleteAlias"]) &&
      toset(statement.NotResource) == toset([
        "arn:aws:events:us-east-1:000000000002:rule/honua-gate-*",
        "arn:aws:kms:us-east-1:000000000002:alias/honua-gate-*"
      ]), false)
    ]) && aws_iam_role_policy_attachment.cloudformation_fences.role == aws_iam_role.cloudformation.name
    error_message = "An attached unconditional deny must fence teardown by exact service, account, region and gate prefix."
  }
  assert {
    condition = alltrue([for arn in [
      "arn:aws:events:us-east-1:000000000002:rule/honua-gate-synthetic-OpsAlarmEvents",
      "arn:aws:kms:us-east-1:000000000002:alias/honua-gate-synthetic-key"
    ] : anytrue([for pattern in local.named_teardown_deny.NotResource : can(regex("^${replace(pattern, "*", ".*")}$", arn))])]) && alltrue([
      for arn in [
        "arn:aws:events:us-east-1:000000000002:rule/foreign-rule",
        "arn:aws:kms:us-east-1:000000000002:alias/foreign-key",
        "arn:aws:events:us-east-1:000000000003:rule/honua-gate-foreign-account",
        "arn:aws:kms:us-west-2:000000000002:alias/honua-gate-foreign-region",
        "arn:aws:kms:us-east-1:000000000002:key/honua-gate-not-an-alias"
      ] : !anytrue([for pattern in local.named_teardown_deny.NotResource : can(regex("^${replace(pattern, "*", ".*")}$", arn))])
    ])
    error_message = "Gate names are eligible; foreign names, accounts, regions and KMS keys stay denied."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : try(
      statement.Sid == "ReaperRule" && statement.Effect == "Deny" && statement.Action == "events:*" &&
      statement.Resource == "arn:aws:events:us-east-1:000000000002:rule/honua-gate-nightly-reaper", false
    )])
    error_message = "The gate reaper remains protected even though its name has the gate prefix."
  }
  assert {
    condition = alltrue([for action in ["kms:UpdateAlias", "kms:ScheduleKeyDeletion", "ec2:DeleteVpc", "ec2:DeleteInternetGateway", "ec2:DetachInternetGateway"] :
      !anytrue([for pattern in local.service_role_ownership_deny.NotAction : can(regex("(?i)^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "Alias reassignment, key deletion and untagged network changes must retain the ownership deny."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(statement.Sid, "") != "NamedTeardownFence"])
    error_message = "The service-role exception must not change the workload boundary."
  }
}
