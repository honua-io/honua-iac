# Synthetic fixtures only: the gate test zone and its service-role-only record exemption.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/client-secret-abcdef" } }
  mock_resource "aws_cognito_user_pool" { defaults = { id = "us-east-1_Synthetic", arn = "arn:aws:cognito-idp:us-east-1:000000000002:userpool/us-east-1_Synthetic" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::000000000002:role/mock" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
  mock_resource "aws_route53_zone" { defaults = { zone_id = "ZSYNTHETICGATE", arn = "arn:aws:route53:::hostedzone/ZSYNTHETICGATE", name_servers = ["ns-1.example.invalid", "ns-2.example.invalid"] } }
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

run "no_test_domain_creates_no_zone_or_exemption" {
  command = plan
  assert {
    condition     = length(aws_route53_zone.gate_test) == 0 && length(aws_route53_record.gate_test_delegation) == 0
    error_message = "An empty gate_test_domain must create no zone and no delegation."
  }
  assert {
    condition     = !anytrue([for arn in local.service_role_ownership_deny.NotResource : strcontains(arn, ":hostedzone/")])
    error_message = "Without a test zone every hosted zone stays fenced."
  }
}

run "test_zone_records_are_service_role_only" {
  command = plan
  variables {
    gate_test_domain         = "gate.example.org"
    gate_test_parent_zone_id = "ZPARENTSYNTHETIC"
  }
  assert {
    condition     = aws_route53_zone.gate_test[0].name == "gate.example.org" && aws_route53_zone.gate_test[0].tags.HonuaGate == "true"
    error_message = "The test zone must carry the gate tag."
  }
  assert {
    condition = (aws_route53_record.gate_test_delegation[0].zone_id == "ZPARENTSYNTHETIC" &&
      aws_route53_record.gate_test_delegation[0].type == "NS" &&
    aws_route53_record.gate_test_delegation[0].records == toset(["ns-1.example.invalid", "ns-2.example.invalid"]))
    error_message = "The parent zone must delegate the test domain to the test zone's name servers."
  }
  assert {
    condition     = contains(local.service_role_ownership_deny.NotResource, "arn:aws:route53:::hostedzone/ZSYNTHETICGATE")
    error_message = "The service role must be able to write validation and alias records in the test zone."
  }
  assert {
    condition     = !anytrue([for arn in local.boundary_ownership_deny.NotResource : strcontains(arn, ":hostedzone/")])
    error_message = "Workload roles must stay fenced from every hosted zone, including the test zone."
  }
  assert {
    condition     = length(jsonencode(jsondecode(aws_iam_role_policy.cloudformation.policy))) <= 10240
    error_message = "The service role inline policy uses ${nonsensitive(length(jsonencode(jsondecode(aws_iam_role_policy.cloudformation.policy))))} of 10240 characters."
  }
}

run "manual_delegation_without_parent_zone" {
  command = plan
  variables {
    gate_test_domain = "gate.example.org"
  }
  assert {
    condition     = length(aws_route53_zone.gate_test) == 1 && length(aws_route53_record.gate_test_delegation) == 0
    error_message = "Without a parent zone the delegation stays manual."
  }
}

run "test_domain_must_be_a_subdomain" {
  command = plan
  variables {
    gate_test_domain = "example.org"
  }
  expect_failures = [var.gate_test_domain]
}
