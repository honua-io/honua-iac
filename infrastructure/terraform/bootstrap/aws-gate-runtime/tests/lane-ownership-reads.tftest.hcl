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

run "lane_runtime_inspection_is_read_only_and_gate_scoped" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      length([for statement in jsondecode(policy).Statement : statement if try(
        statement.Sid == "InspectGateRuntime" && statement.Effect == "Allow" && !can(statement.Condition) &&
        toset(statement.Action) == toset(["ecs:DescribeTasks", "ecs:DescribeServices", "logs:DescribeLogStreams", "logs:FilterLogEvents", "logs:GetLogEvents", "cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmHistory"]) &&
        toset(statement.Resource) == toset([
          "arn:aws:ecs:us-east-1:000000000002:task/honua-gate-*-Cluster-*/*",
          "arn:aws:ecs:us-east-1:000000000002:service/honua-gate-*-Cluster-*/*",
          "arn:aws:cloudwatch:us-east-1:000000000002:alarm:honua-gate-*",
          "arn:aws:logs:us-east-1:000000000002:log-group:/honua/honua-gate-*",
          "arn:aws:logs:us-east-1:000000000002:log-group:aws-waf-logs-honua-gate-*",
          "arn:aws:logs:us-east-1:000000000002:log-group:/aws/vendedlogs/honua/honua-gate-*",
          "arn:aws:logs:us-east-1:000000000002:log-group:/aws/rds/instance/honua-gate-*"
        ]), false
        )]) == 1 && length([for statement in jsondecode(policy).Statement : statement if try(
        statement.Sid == "ListGateTasks" && statement.Effect == "Allow" && statement.Action == "ecs:ListTasks" && statement.Resource == "*" &&
        statement.Condition.ArnLike["ecs:cluster"] == "arn:aws:ecs:us-east-1:000000000002:cluster/honua-gate-*-Cluster-*", false
      )]) == 1
    ])
    error_message = "Both lane policies must allow only read-only task, service, alarm and log inspection, scoped to gate-named clusters, alarms and log groups in the gate account."
  }
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      !anytrue([for statement in jsondecode(policy).Statement : statement.Effect == "Allow" && anytrue([
        for action in flatten([statement.Action]) : contains(["ecs:DescribeTaskDefinition", "ecs:ExecuteCommand", "logs:StartQuery", "secretsmanager:GetSecretValue", "wafv2:GetLoggingConfiguration", "cloudwatch:GetMetricData", "cloudwatch:ListMetrics", "cloudwatch:PutMetricAlarm", "cloudwatch:SetAlarmState", "cloudwatch:DeleteAlarms", "ecs:UpdateService"], action) || endswith(action, ":*")
      ])])
    ])
    error_message = "Lane runtime inspection must not grant unscoped task-definition reads, command execution, account-wide log queries, secret reads, metric listing, alarm or service writes, or service wildcards."
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

run "lane_simulates_only_gate_roles" {
  command = plan
  assert {
    condition = one([
      for statement in jsondecode(aws_iam_policy.lane_boundary.policy).Statement : statement
      if try(statement.Sid, "") == "SimulateGateRoles"
      ]).Resource == "arn:aws:iam::${var.member_account_id}:role/honua-gate-*" && toset(one([
        for statement in jsondecode(aws_iam_policy.lane_boundary.policy).Statement : statement
        if try(statement.Sid, "") == "SimulateGateRoles"
      ]).Action) == toset(["iam:SimulatePrincipalPolicy", "iam:GetContextKeysForPrincipalPolicy", "iam:GetRole"]) && !anytrue([
      for statement in jsondecode(aws_iam_policy.lane_boundary.policy).Statement :
      statement.Effect == "Allow" && anytrue([for action in flatten([statement.Action]) : startswith(action, "iam:") && !contains(["iam:PassRole", "iam:SimulatePrincipalPolicy", "iam:GetContextKeysForPrincipalPolicy", "iam:GetRole"], action)])
    ])
    error_message = "The lane may simulate and read gate roles only, and gains no other IAM action."
  }
}

run "lane_reads_config_and_log_group_metadata_only" {
  command = plan
  variables {
    config_reads = ["config:DescribeConfigurationRecorder*", "config:DescribeDeliveryChannel*", "config:DescribeConfigRule*", "config:DescribeComplianceByConfigRule"]
  }
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      length([for statement in jsondecode(policy).Statement : statement if try(
        statement.Sid == "InspectGateMetadata" && statement.Effect == "Allow" && statement.Resource == "*" && !can(statement.Condition) &&
        toset(statement.Action) == toset(concat(var.config_reads, ["logs:DescribeLogGroups", "logs:DescribeDeliver*", "cloudwatch:GetMetricStatistics"])), false
        )]) == 1 && !anytrue([for statement in jsondecode(policy).Statement : statement.Effect == "Allow" && (can(statement.NotAction) || anytrue([
          for action in flatten([try(statement.Action, [])]) : startswith(action, "config:") && !contains(var.config_reads, action)
      ]))])
    ])
    error_message = "Both lane policies may read Config recorder, delivery channel, rule and rule-compliance metadata, log group and log delivery metadata and metric statistics only: no other Config action and no NotAction allow."
  }
}

run "lane_reads_vpc_origins_only" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      length([for statement in jsondecode(policy).Statement : statement if try(
        statement.Sid == "InspectVpcOrigins" && statement.Effect == "Allow" && !can(statement.Condition) &&
        toset(statement.Action) == toset(["cloudfront:GetVpcOrigin", "cloudfront:ListTagsForResource"]) &&
        statement.Resource == "arn:aws:cloudfront::000000000002:vpcorigin/*", false
        )]) == 1 && !anytrue([for statement in jsondecode(policy).Statement : statement.Effect == "Allow" && anytrue([
          for action in flatten([try(statement.Action, [])]) : startswith(action, "cloudfront:") && !contains(["cloudfront:GetVpcOrigin", "cloudfront:ListTagsForResource"], action)
      ])])
    ])
    error_message = "Both lane policies may read VPC origins and their tags only: no other CloudFront action, and no distribution, function or policy reads."
  }
}
