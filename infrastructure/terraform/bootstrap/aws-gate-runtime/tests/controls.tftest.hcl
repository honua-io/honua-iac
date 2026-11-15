# Synthetic fixtures only; deployment identifiers come from private SSM configuration.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::000000000002:role/mock" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
  mock_resource "aws_lambda_function" { defaults = { arn = "arn:aws:lambda:us-east-1:000000000002:function:honua-gate-reaper" } }
  mock_resource "aws_cloudwatch_event_rule" { defaults = { arn = "arn:aws:events:us-east-1:000000000002:rule/mock" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-east-1:000000000002:log-group:/aws/lambda/honua-gate-reaper" } }
}
mock_provider "archive" {}
variables {
  member_account_id   = format("%012d", 2)
  lane_principal_arns = [format("arn:aws:iam::%s:role/GateOperator", format("%012d", 1))]
}
run "lane_is_stack_only_and_workloads_are_bounded" {
  command = plan
  assert {
    condition     = jsondecode(aws_iam_role_policy.lane.policy).Statement[0].Resource == format("arn:aws:cloudformation:us-east-1:%s:stack/honua-gate-*/*", format("%012d", 2)) && jsondecode(aws_iam_role_policy.lane.policy).Statement[0].Condition.StringEquals["cloudformation:RoleArn"] == local.service_role_arn
    error_message = "Lane mutations require a gate stack name and the single service role."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.cloudformation.policy).Statement[2].Condition.ArnEquals["iam:PermissionsBoundary"] == aws_iam_policy.workload_boundary.arn
    error_message = "CloudFormation must enforce the workload boundary at role creation."
  }
  assert {
    condition     = jsondecode(aws_iam_policy.workload_boundary.policy).Statement[0].Effect == "Deny" && jsondecode(aws_iam_role_policy.cloudformation.policy).Statement[0] == jsondecode(aws_iam_policy.workload_boundary.policy).Statement[0]
    error_message = "Templates and workload code must be unable to modify the reaper."
  }
  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.cloudformation.policy).Statement[5].Condition.StringEquals["iam:AWSServiceName"], "ecs.application-autoscaling.amazonaws.com") && contains(jsondecode(aws_iam_role_policy.cloudformation.policy).Statement[5].Condition.StringEquals["iam:AWSServiceName"], "guardduty.amazonaws.com")
    error_message = "A fresh account must permit the ECS autoscaling and GuardDuty service-linked roles."
  }
  assert {
    condition     = aws_cloudwatch_event_rule.nightly.schedule_expression == "cron(0 3 * * ? *)" && aws_lambda_function.reaper.environment[0].variables["SERVICE_ROLE_ARN"] == local.service_role_arn
    error_message = "The nightly reaper must delete through the same service role."
  }
  assert {
    condition     = length(aws_budgets_budget.shared) == 0 && length(local.region_controls) == 0 && length(local.shared_controls) == 0
    error_message = "Default member-account behavior must remain unchanged."
  }
  assert {
    condition     = alltrue([for sid in ["NameFence", "ReaperRule", "DenySharedBudget"] : anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(statement.Sid == sid && statement.Effect == "Deny", false)])])
    error_message = "Member mode must keep the gate-name fence and the reaper and budget denies."
  }
}
run "wildcard_trust_is_rejected" {
  command = plan
  variables { lane_principal_arns = [format("arn:aws:iam::%s:role/*", format("%012d", 1))] }
  expect_failures = [var.lane_principal_arns]
}
run "shared_account_denies_and_alert_budget" {
  command = plan
  variables {
    shared_account          = true
    protected_state_buckets = ["synthetic-state"]
    protected_ssm_paths     = ["/synthetic/gate"]
    budget_alert_email      = "gate@example.invalid"
  }
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_role_policy.cloudformation.policy, aws_iam_policy.workload_boundary.policy] : anytrue([
      for statement in jsondecode(policy).Statement : try(statement.Sid == "DenyOtherRegions" && statement.Effect == "Deny" && statement.Condition.StringNotEquals["aws:RequestedRegion"] == "us-east-1" && toset(statement.NotAction) == toset(["iam:*", "route53:*", "cloudfront:*"]), false)
    ])])
    error_message = "All lane, service and workload identities must carry the region deny."
  }
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.workload_boundary.policy] : alltrue([
      for sid in ["DenyOtherBuckets", "DenyState", "DenyPrivateParameters", "DenyNonGateChanges", "DenyNonGateContentReads"] : anytrue([for statement in jsondecode(policy).Statement : try(statement.Sid == sid && statement.Effect == "Deny", false)])
    ])])
    error_message = "Service and workload identities must protect existing shared resources."
  }
  assert {
    condition = alltrue([
      for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.workload_boundary.policy] : anytrue([
        for statement in jsondecode(policy).Statement : try(statement.Sid == "DenyNonGateChanges" && statement.Condition.StringNotLikeIfExists["aws:ResourceTag/aws:cloudformation:stack-name"] == "honua-gate-*" && !contains(statement.NotAction, "ec2:CreateTags") && !contains(statement.NotAction, "route53:ChangeResourceRecordSets"), false)
      ])
    ]) && contains(local.service_role_ownership_deny.NotAction, "secretsmanager:Get*") && !contains(local.boundary_ownership_deny.NotAction, "secretsmanager:Get*")
    error_message = "Missing ownership tags must deny mutation. Only the service role keeps account-wide metadata reads."
  }
  assert {
    condition     = contains(local.shared_controls[1].Resource, "arn:aws:s3:::synthetic-state/*") && local.shared_controls[2].Resource == "*" && local.shared_controls[2].Action == "ssm:*" && local.shared_controls[2].Effect == "Deny"
    error_message = "State objects and all private SSM parameters need explicit protection."
  }
  assert {
    condition     = length(aws_iam_policy.workload_boundary.policy) <= 6144 && length(aws_iam_role_policy.cloudformation.policy) <= 10240
    error_message = "Generated policies must fit AWS managed and inline policy size limits."
  }
  assert {
    condition     = local.stack_tag_controls[0].Effect == "Deny" && local.stack_tag_controls[0].Condition.StringNotEqualsIfExists["aws:RequestTag/HonuaGate"] == "true"
    error_message = "Gate creation and updates must include the budget allocation tag."
  }
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] : anytrue([
      for statement in jsondecode(policy).Statement : try(statement.Sid == "TagGateStacks" && statement.Effect == "Allow" && statement.Action == "cloudformation:TagResource" && statement.Resource == local.stack_arn && toset(statement.Condition.StringEquals["cloudformation:CreateAction"]) == toset(["CreateStack", "UpdateStack"]), false)
    ])])
    error_message = "Tagged stack creation and updates require tagging permission in both lane policies."
  }
  assert {
    condition     = aws_budgets_budget.shared[0].limit_amount == "300" && one(aws_budgets_budget.shared[0].cost_filter).name == "TagKeyValue" && one(one(aws_budgets_budget.shared[0].cost_filter).values) == "user:HonuaGate$true" && one(aws_budgets_budget.shared[0].notification).threshold == 80
    error_message = "Shared mode must budget only gate-tagged costs with an 80 percent alert."
  }
  assert {
    condition = alltrue([
      for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.workload_boundary.policy] : alltrue([
        for action in ["kms:*", "cloudwatch:*", "sns:*", "sqs:*", "events:*", "cloudtrail:*", "budgets:*", "ce:*", "guardduty:*", "backup:*"] : anytrue([
          for statement in jsondecode(policy).Statement : try(statement.Effect == "Allow" && contains(statement.Action, action), false)
        ])
      ])
    ]) && alltrue([for action in ["ssm:*", "bedrock:*", "bedrock-agentcore:*", "securityhub:*", "scheduler:*"] : !contains(local.workload_services, action)])
    error_message = "Launch Stack services must be allowed, and SSM, agents, Security Hub and Scheduler must stay out of the workload allow."
  }
  assert {
    condition = alltrue([
      for action in ["kms:CreateKey", "kms:CreateAlias", "cloudwatch:PutMetricAlarm", "cloudwatch:PutCompositeAlarm", "sns:CreateTopic", "sqs:CreateQueue", "events:PutRule", "events:PutTargets", "cloudtrail:CreateTrail", "budgets:ModifyBudget", "ce:CreateAnomalyMonitor", "ce:CreateAnomalySubscription", "guardduty:CreateDetector"] : contains(local.shared_creation_actions, action)
    ])
    error_message = "Resource allocation APIs for the added Launch Stack services must remain available before a stack tag exists."
  }
  assert {
    condition = alltrue([
      for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.workload_boundary.policy] : alltrue([
        anytrue([for statement in jsondecode(policy).Statement : try(statement.Sid == "NameFence" && statement.Effect == "Deny" && toset(statement.NotResource) == toset(["arn:aws:events:us-east-1:${format("%012d", 2)}:rule/honua-gate-*", "arn:aws:cloudwatch:us-east-1:${format("%012d", 2)}:alarm:honua-gate-*", "arn:aws:budgets::${format("%012d", 2)}:budget/honua-gate-*"]), false)]),
        anytrue([for statement in jsondecode(policy).Statement : try(statement.Sid == "ReaperRule" && statement.Action == "events:*" && statement.Resource == "arn:aws:events:us-east-1:${format("%012d", 2)}:rule/honua-gate-nightly-reaper", false)]),
        anytrue([for statement in jsondecode(policy).Statement : try(statement.Sid == "DenySharedBudget" && statement.Action == "budgets:*" && statement.Resource == "arn:aws:budgets::${format("%012d", 2)}:budget/honua-gate-shared-monthly", false)])
      ])
    ])
    error_message = "Create-and-update APIs must stay on gate names, and the reaper schedule and shared budget stay denied."
  }
}
run "shared_account_requires_private_protection_inputs" {
  command = plan
  variables { shared_account = true }
  expect_failures = [var.protected_state_buckets, var.protected_ssm_paths, var.budget_alert_email]
}

run "shared_account_policy_quotas_with_deployment_sized_inputs" {
  command = plan
  variables {
    shared_account          = true
    protected_state_buckets = [for index in range(2) : format("synthetic-state-%047d", index)]
    protected_ssm_paths     = [for index in range(18) : format("/synthetic/gate/runtime/protected-parameter-%02d", index)]
    budget_alert_email      = "gate@example.invalid"
  }
  assert {
    condition = alltrue([
      for policy in [aws_iam_policy.lane_boundary.policy, aws_iam_policy.workload_boundary.policy] :
      length(jsonencode(jsondecode(policy))) <= 6144
    ])
    error_message = "Every managed policy must fit the 6144-character quota with 18 protected paths and two state buckets."
  }
  assert {
    condition = alltrue([
      for policy in [aws_iam_role_policy.lane.policy, aws_iam_role_policy.cloudformation.policy, aws_iam_role_policy.reaper.policy] :
      length(jsonencode(jsondecode(policy))) <= 10240
    ])
    error_message = "Every inline role policy must fit the 10240-character quota."
  }
  assert {
    condition = alltrue([
      for policy in [aws_iam_role.lane.assume_role_policy, aws_iam_role.cloudformation.assume_role_policy, aws_iam_role.reaper.assume_role_policy] :
      length(jsonencode(jsondecode(policy))) <= 2048
    ])
    error_message = "Every role trust policy must fit the 2048-character quota."
  }
}
