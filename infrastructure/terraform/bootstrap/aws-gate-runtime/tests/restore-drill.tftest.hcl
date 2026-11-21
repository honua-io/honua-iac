# Synthetic fixtures only. A restore drill stack restores a gate database from an AWS Backup snapshot through the
# service role, and a drill runner task polls Backup job status; nothing else about either fence widens.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/client-secret-abcdef" } }
  mock_resource "aws_cognito_user_pool" { defaults = { id = "us-east-1_Synthetic", arn = "arn:aws:cognito-idp:us-east-1:000000000002:userpool/us-east-1_Synthetic" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::000000000002:role/mock" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
  mock_resource "aws_lambda_function" { defaults = { arn = "arn:aws:lambda:us-east-1:000000000002:function:honua-gate-reaper" } }
  mock_resource "aws_cloudwatch_event_rule" { defaults = { arn = "arn:aws:events:us-east-1:000000000002:rule/mock" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-east-1:000000000002:log-group:/aws/lambda/honua-gate-reaper" } }
}
mock_provider "archive" {}
variables {
  member_account_id       = format("%012d", 2)
  lane_principal_arns     = [format("arn:aws:iam::%s:role/GateOperator", format("%012d", 1))]
  shared_account          = true
  budget_alert_email      = "gate@example.invalid"
  protected_state_buckets = ["synthetic-state"]
  protected_ssm_paths     = ["/synthetic/gate/runtime/protected"]
}

run "service_role_restores_only_gate_snapshots" {
  command = plan
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement : try(
      statement.Sid == "DenyNonGateChanges" && contains(statement.NotAction, "rds:RestoreDBInstanceFromDBSnapshot"), false)
    ])
    error_message = "The service role must be able to restore a database whose new instance has no tags yet."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_restores.policy).Statement : try(
      statement.Sid == "RestoreGateSnapshots" && statement.Effect == "Deny" && statement.Action == "rds:RestoreDBInstanceFromDBSnapshot" &&
      statement.Resource == "arn:aws:rds:us-east-1:${var.member_account_id}:snapshot:*" &&
      statement.Condition == { StringNotEqualsIfExists = { "aws:ResourceTag/HonuaGate" = "true" } }, false)
    ])
    error_message = "A restore must be denied on any snapshot without the gate cost tag."
  }
  assert {
    # Resources a restore names that must fall outside RestoreGateTargets' NotResource, so the deny applies.
    condition = alltrue([for arn in [
      "arn:aws:rds:us-east-1:${var.member_account_id}:cluster-snapshot:honua-gate-source",
      "arn:aws:rds:us-east-1:${format("%012d", 9)}:snapshot:shared-from-elsewhere",
      "arn:aws:rds:us-west-2:${var.member_account_id}:snapshot:awsbackup:job-1",
      "arn:aws:rds:us-east-1:${var.member_account_id}:db:customer-database",
      "arn:aws:rds:us-east-1:${var.member_account_id}:subgrp:default",
      "arn:aws:rds:us-east-1:${var.member_account_id}:db-capacity-reservation:any"
      ] : anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_restores.policy).Statement : try(
        statement.Sid == "RestoreGateTargets" && statement.Effect == "Deny" && statement.Action == "rds:RestoreDBInstanceFromDBSnapshot" &&
        !anytrue([for pattern in statement.NotResource : can(regex("^${replace(pattern, "*", ".*")}$", arn))]), false)
    ])])
    error_message = "Cluster, foreign-account and other-region snapshots and non-gate instances and subnet groups must stay denied."
  }
  assert {
    condition = alltrue([for arn in [
      "arn:aws:rds:us-east-1:${var.member_account_id}:snapshot:awsbackup:job-1",
      "arn:aws:rds:us-east-1:${var.member_account_id}:db:honua-gate-drill-database-abc",
      "arn:aws:rds:us-east-1:${var.member_account_id}:subgrp:honua-gate-drill-databasesubnets-abc",
      "arn:aws:rds:us-east-1:${var.member_account_id}:og:default:postgres-16",
      "arn:aws:rds:us-east-1:${var.member_account_id}:pg:default.postgres16"
      ] : anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_restores.policy).Statement : try(
        statement.Sid == "RestoreGateTargets" && anytrue([for pattern in statement.NotResource : can(regex("^${replace(pattern, "*", ".*")}$", arn))]), false)
    ])])
    error_message = "A gate snapshot restore into a gate-named instance and subnet group with default groups must remain possible."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.cloudformation_restores.role == aws_iam_role.cloudformation.name
    error_message = "The restore fences must be attached to the service role."
  }
  assert {
    # The new instance keeps the RDS creation tag fence in the attached fences policy.
    condition = anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : try(
    statement.Sid == "RDSCreationTags" && statement.Action == "rds:AddTagsToResource", false)])
    error_message = "Restored instances must keep the gate tag fence."
  }
}

run "workloads_poll_backup_jobs_but_restore_nothing_new" {
  command = plan
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(
      statement.Sid == "DenyNonGateChanges" && contains(statement.NotAction, "backup:Describe*Job") &&
      !anytrue([for action in statement.NotAction : startswith(action, "rds:Restore") || startswith(action, "backup:Start") || startswith(action, "backup:Get")]), false)
    ])
    error_message = "Workloads may read Backup job status; restores and recovery point reads stay behind the ownership tags."
  }
}

run "unmatched_read_patterns_change_no_permission" {
  command = plan
  assert {
    # No content-read action matches a removed pattern, so the content-read deny is unchanged without them.
    condition = alltrue([for action in local.shared_content_read_actions : !anytrue([
      for pattern in local.unmatched_read_patterns : can(regex("^${replace(pattern, "*", ".*")}$", action))
    ])]) && alltrue([for pattern in local.unmatched_read_patterns : !contains(local.metadata_read_actions, pattern)])
    error_message = "Only patterns that match no API, and no content read, may leave the metadata reads."
  }
}

# A stack backup role takes AWS Backup database backups of gate databases only and never tags a snapshot.
run "backup_role_snapshots_gate_databases_only" {
  command = plan
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(
      statement.Sid == "DenyNonGateChanges" && contains(statement.NotAction, "rds:DescribeDBSnapshots") &&
      contains(statement.NotAction, "rds:CreateDBSnapshot") && !contains(statement.NotAction, "rds:AddTagsToResource") &&
      !anytrue([for action in statement.NotAction : startswith(action, "rds:Restore") || startswith(action, "rds:Copy") || startswith(action, "rds:Delete")]), false)
    ])
    error_message = "AWS Backup may look up and create its snapshot; tagging, copying, deleting and restoring stay behind the ownership tags."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(
      statement.Effect == "Deny" && statement.Action == "rds:CreateDBSnapshot" &&
      statement.Resource == "arn:aws:rds:us-east-1:${var.member_account_id}:db:*" &&
      statement.Condition.StringNotLikeIfExists["aws:ResourceTag/aws:cloudformation:stack-name"] == "honua-gate-*" &&
      statement.Condition.StringNotEqualsIfExists["aws:ResourceTag/HonuaGate"] == "true", false)
    ])
    error_message = "A snapshot's source database must carry the gate ownership tags."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(
      statement.Effect == "Deny" && statement.Action == "rds:CreateDBSnapshot" && statement.NotResource == [
        "arn:aws:rds:us-east-1:${var.member_account_id}:db:*", "arn:aws:rds:us-east-1:${var.member_account_id}:snapshot:awsbackup:*"
      ], false)
    ]) && alltrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : !contains(flatten([try(statement.NotAction, [])]), "rds:CreateDBClusterSnapshot")])
    error_message = "Workloads create only AWS Backup-named instance snapshots; cluster snapshots stay behind the ownership tags."
  }
  assert {
    condition     = length(jsonencode(jsondecode(aws_iam_policy.workload_boundary.policy))) <= 6144
    error_message = "The workload boundary uses ${nonsensitive(length(jsonencode(jsondecode(aws_iam_policy.workload_boundary.policy))))} of 6144 characters."
  }
}
