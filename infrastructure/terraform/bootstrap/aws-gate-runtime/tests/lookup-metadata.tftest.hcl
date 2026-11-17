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

run "lookup_role_can_discover_network_metadata" {
  command = plan
  assert {
    condition = alltrue([
      for action in ["ec2:DescribeManagedPrefixLists", "ec2:DescribeAvailabilityZones", "ec2:DescribeSubnets", "ec2:DescribeVpcs"] :
      anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("(?i)^${replace(pattern, "*", ".*")}$", action))]) &&
      anytrue([for pattern in local.workload_services : can(regex("(?i)^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "Lookup Lambda metadata calls have no ownership tags and must pass the workload boundary."
  }
}

run "lookup_exception_preserves_foreign_resource_fences" {
  command = plan
  assert {
    condition = alltrue([
      for action in ["ec2:DeleteVpc", "ec2:ModifySubnetAttribute", "ec2:CreateTags", "ec2:DescribeInstanceAttribute", "ec2:DescribeKeyPairs", "ec2:DescribeLaunchTemplateVersions", "ec2:DescribeVpnConnections"] :
      !anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("(?i)^${replace(pattern, "*", ".*")}$", action))])
    ]) && { for key, value in local.boundary_ownership_deny.Condition : key => value if key != "StringNotEquals" } == local.ownership_condition && local.boundary_ownership_deny.Condition.StringNotEquals == { "kms:ViaService" = "secretsmanager.us-east-1.amazonaws.com" }
    error_message = "Network mutations and sensitive EC2 reads must retain the foreign-resource ownership deny."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(
      statement.Sid == "DenyOtherRegions" && statement.Effect == "Deny" && statement.Resource == "*" &&
      statement.Condition.StringNotEquals["aws:RequestedRegion"] == "us-east-1" &&
      !anytrue([for pattern in statement.NotAction : can(regex("(?i)^${replace(pattern, "*", ".*")}$", "ec2:DescribeManagedPrefixLists"))]), false
    )])
    error_message = "Network metadata access remains confined to the gate region."
  }
}
