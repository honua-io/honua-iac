mock_provider "aws" {
  override_during = plan
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/client-secret-abcdef" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
}
mock_provider "archive" {}

variables {
  member_account_id       = format("%012d", 2)
  lane_principal_arns     = [format("arn:aws:iam::%s:role/GateOperator", format("%012d", 1))]
  shared_account          = true
  protected_state_buckets = ["synthetic-state"]
  protected_ssm_paths     = ["/synthetic/gate"]
  budget_alert_email      = "gate@example.invalid"
}

run "foreign_and_untagged_secret_reads_are_denied" {
  command = plan
  assert {
    condition = alltrue([
      for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.workload_boundary.policy] : alltrue([
        for action in ["secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue"] : alltrue([
          for ownership in ["existing-stack", ""] : anytrue([
            for statement in jsondecode(policy).Statement : try(
              statement.Effect == "Deny" && statement.NotResource == aws_secretsmanager_secret.idp_client.arn && (try(contains(statement.Action, action), false) || try(!anytrue([for pattern in statement.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))]), false)) &&
              !startswith(ownership, trimsuffix(statement.Condition.StringNotLikeIfExists["aws:ResourceTag/aws:cloudformation:stack-name"], "*")), false
            )
          ])
        ])
      ])
    ])
    error_message = "Both identities must explicitly deny foreign and absent-tag secret reads, including batch reads."
  }
}

run "gate_secret_single_read_keeps_its_allow" {
  command = plan
  assert {
    condition = alltrue([
      for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.workload_boundary.policy] :
      anytrue([for statement in jsondecode(policy).Statement : try(statement.Effect == "Allow" && statement.Resource == "*" && contains(statement.Action, "secretsmanager:*"), false)]) &&
      anytrue([for statement in jsondecode(policy).Statement : try(
        contains(["DenyNonGateContentReads", "DenyNonGateChanges"], statement.Sid) && statement.Effect == "Deny" &&
        startswith("honua-gate-synthetic", trimsuffix(statement.Condition.StringNotLikeIfExists["aws:ResourceTag/aws:cloudformation:stack-name"], "*")), false
      )]) &&
      anytrue([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement : try(statement.Sid == "DenyNonGateChanges" && contains(statement.NotAction, "secretsmanager:Get*"), false)]) &&
      anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(statement.Sid == "DenyNonGateChanges" && !contains(statement.NotAction, "secretsmanager:Get*"), false)])
    ])
    error_message = "The ownership deny must preserve GetSecretValue for an immutable gate stack tag."
  }
}

run "content_read_families_are_guarded_in_both_policies" {
  command = plan
  assert {
    condition = alltrue([
      for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.workload_boundary.policy] : alltrue([
        for action in ["lambda:GetFunction", "lambda:ListEventSourceMappings", "wafv2:GetWebACL", "rds:DescribeDBProxyTargetGroups", "logs:GetLogEvents", "logs:FilterLogEvents", "logs:GetLogRecord", "logs:StartQuery", "logs:GetQueryResults", "logs:StartLiveTail", "ec2:GetPasswordData", "ec2:GetConsoleOutput", "ec2:GetConsoleScreenshot", "ecs:ExecuteCommand", "rds:StartExportTask", "backup:GetRecoveryPointRestoreMetadata", "cloudfront:GetPublicKey", "cloudfront:GetFieldLevelEncryption", "ecr:GetAuthorizationToken", "wafv2:GetDecryptedAPIKey", "kms:Decrypt", "kms:GenerateDataKey", "kms:GetKeyPolicy", "ce:GetCostAndUsage", "cloudtrail:LookupEvents", "cloudtrail:GetQueryResults", "cloudwatch:GetDashboard", "guardduty:GetFindings", "sqs:ReceiveMessage", "sns:GetSMSAttributes"] : anytrue([
          for statement in jsondecode(policy).Statement : try(
            statement.Effect == "Deny" && statement.NotResource == aws_secretsmanager_secret.idp_client.arn && statement.Condition.StringNotLikeIfExists["aws:ResourceTag/aws:cloudformation:stack-name"] == "honua-gate-*" &&
            (try(anytrue([for pattern in statement.Action : can(regex("^${replace(pattern, "*", ".*")}$", action))]), false) || try(!anytrue([for pattern in statement.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))]), false)), false
          )
        ])
      ])
    ])
    error_message = "Content APIs must require gate ownership in the service and workload policies."
  }
}
