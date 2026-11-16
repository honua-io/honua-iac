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

run "lane_can_inspect_resource_ownership" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      anytrue([for statement in jsondecode(policy).Statement : try(
        statement.Effect == "Allow" && statement.Action == "ec2:Describe*" && statement.Resource == "*", false
        )]) && anytrue([for statement in jsondecode(policy).Statement : try(
        statement.Effect == "Allow" && statement.Action == "kms:ListResourceTags" &&
        statement.Resource == "arn:aws:kms:us-east-1:000000000002:key/*", false
      )])
    ])
    error_message = "Lane permissions and their boundary must both allow EC2 inspection and KMS key-tag reads in the gate account and region."
  }
}

run "lane_inspection_cannot_read_ec2_content" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      alltrue([for action in ["ec2:DescribeInstanceAttribute", "ec2:DescribeKeyPairs", "ec2:DescribeLaunchTemplateVersions", "ec2:DescribeVpnConnections"] :
        anytrue([for statement in jsondecode(policy).Statement : try(
          statement.Effect == "Deny" && statement.Resource == "*" &&
          contains(statement.Action, action) && !can(statement.Condition), false
        )])
      ])
    ])
    error_message = "Both lane policies must deny EC2 content reads unconditionally, including resources with gate ownership tags."
  }
}
