# Synthetic fixtures only. WAF logging needs a log delivery (resource *) and a delivery resource policy; the service
# role may manage deliveries, while the account log resource policy stays denied and is owned by this root.
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

run "service_role_may_create_waf_log_deliveries_but_not_resource_policies" {
  command = plan
  assert {
    condition = alltrue([for action in ["logs:CreateLogDelivery", "logs:DeleteLogDelivery", "logs:UpdateLogDelivery"] :
      anytrue([for pattern in local.service_role_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "The service role must be able to create, update and delete WAF log deliveries."
  }
  assert {
    condition = alltrue([for action in ["logs:PutResourcePolicy", "logs:DeleteResourcePolicy", "logs:PutAccountPolicy", "logs:PutDeliveryDestinationPolicy"] : alltrue([
      for deny in [local.boundary_ownership_deny, local.service_role_ownership_deny] : !anytrue([for pattern in deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])])
    error_message = "Account-level log policies must stay behind the ownership deny."
  }
  assert {
    condition     = !anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", "logs:CreateLogDelivery"))])
    error_message = "Workload roles have no reason to manage log deliveries."
  }
}

run "delivery_policy_reaches_only_gate_waf_log_groups_in_this_account" {
  command = plan
  assert {
    condition = jsondecode(aws_cloudwatch_log_resource_policy.gate_waf_logs[0].policy_document).Statement == [{
      Sid       = "GateWafLogDelivery"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "arn:aws:logs:us-east-1:000000000002:log-group:aws-waf-logs-honua-gate-*:log-stream:*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = "000000000002" }
        ArnLike      = { "aws:SourceArn" = "arn:aws:logs:us-east-1:000000000002:*" }
      }
    }]
    error_message = "The delivery policy must name the delivery service, gate WAF log groups and this account only."
  }
}

run "edge_access_log_policy_reaches_only_gate_vended_log_groups_in_this_account" {
  command = plan
  assert {
    condition = jsondecode(aws_cloudwatch_log_resource_policy.gate_edge_access_logs[0].policy_document).Statement == [{
      Sid       = "GateEdgeAccessLogDelivery"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "arn:aws:logs:us-east-1:000000000002:log-group:/aws/vendedlogs/honua/honua-gate-*:log-stream:*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = "000000000002" }
        ArnLike      = { "aws:SourceArn" = "arn:aws:logs:us-east-1:000000000002:*" }
      }
    }]
    error_message = "The edge access-log delivery policy must name the delivery service, gate vended-log groups and this account only."
  }
}

run "edge_access_log_resources_can_be_tagged_on_create" {
  command = plan
  assert {
    condition = alltrue([for arn in [
      "arn:aws:logs:us-east-1:000000000002:log-group:/aws/vendedlogs/honua/honua-gate-*",
      "arn:aws:logs:us-east-1:000000000002:delivery-source:honua-*-edge",
      "arn:aws:logs:us-east-1:000000000002:delivery-destination:honua-*-edge",
      "arn:aws:logs:us-east-1:000000000002:delivery:*"
    ] : contains(local.named_tag_targets["logs:TagResource"], arn)])
    error_message = "CloudFront access-log resources must pass the first-tag name fence."
  }
}

# Gate create 2220z: CloudWatch Logs refused GetDeliveryDestination and DeleteDeliveryDestination on a destination
# created with HonuaGate=true, so delivery resources are fenced by account and name, not by resource tags.
run "service_role_manages_this_accounts_delivery_resources_outside_the_tag_denies" {
  command = plan
  assert {
    condition = contains(local.service_role_ownership_deny.NotResource, "arn:aws:logs:*:*:delivery*") && alltrue([for action in ["logs:GetDeliveryDestination", "logs:DeleteDeliveryDestination"] :
      !anytrue([for pattern in local.service_role_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "The service role must read, update and delete its delivery resources, which carry no evaluable resource tags."
  }
  assert {
    condition = !anytrue([for arn in local.boundary_ownership_deny.NotResource : strcontains(arn, ":delivery")]) && !anytrue([
      for action in local.delivery_creation_actions : anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "Workload roles stay behind the ownership deny for delivery resources."
  }
}

run "delivery_resources_are_fenced_by_account_and_launch_stack_name" {
  command = plan
  assert {
    condition = length([for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : statement if try(
      statement.Sid == "DeliveryCreationTags" && statement.Resource == "*" &&
      toset(statement.Action) == toset(["logs:PutDeliverySource", "logs:PutDeliveryDestination", "logs:CreateDelivery"]) &&
      statement.Condition.StringNotEqualsIfExists["aws:RequestTag/HonuaGate"] == "true", false
    )]) == 1
    error_message = "Delivery creates and overwrites must carry HonuaGate=true."
  }
  assert {
    condition = length([for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : statement if try(
      statement.Sid == "DeliveryNames" && statement.Effect == "Deny" &&
      alltrue([for action in ["logs:GetDeliverySource", "logs:PutDeliverySource", "logs:DeleteDeliverySource", "logs:GetDeliveryDestination", "logs:PutDeliveryDestination", "logs:DeleteDeliveryDestination", "logs:CreateDelivery", "logs:UpdateDeliveryConfiguration"] :
      anytrue([for pattern in statement.Action : can(regex("^${replace(pattern, "*", ".*")}$", action))])]) &&
      !anytrue([for action in ["logs:DescribeDeliverySources", "logs:DescribeDeliveryDestinations", "logs:CreateLogDelivery"] :
      anytrue([for pattern in statement.Action : can(regex("^${replace(pattern, "*", ".*")}$", action))])]) &&
      toset(statement.NotResource) == toset([
        "arn:aws:logs:us-east-1:000000000002:delivery-source:honua-*-edge",
        "arn:aws:logs:us-east-1:000000000002:delivery-destination:honua-*-edge",
        "arn:aws:logs:us-east-1:000000000002:delivery:*"
      ]), false
    )]) == 1
    error_message = "Delivery calls must name a Launch Stack source or destination in this account; resource-less list and WAF delivery calls stay outside the fence."
  }
  assert {
    condition = length([for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : statement if try(
      statement.Sid == "DeliveryDestinationTargets" && statement.Action == "logs:PutDeliveryDestination" &&
      statement.Condition.StringNotLike["logs:DeliveryDestinationResourceArn"] == "arn:aws:logs:us-east-1:000000000002:log-group:/aws/vendedlogs/honua/honua-gate-*", false
      )]) == 1 && length([for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : statement if try(
      statement.Sid == "DeliveryDestinationPolicies" && statement.Action == "logs:PutDeliveryDestinationPolicy" && statement.Resource == "*", false
    )]) == 1
    error_message = "Destinations must target gate vended-log groups and may not get a destination policy."
  }
}
