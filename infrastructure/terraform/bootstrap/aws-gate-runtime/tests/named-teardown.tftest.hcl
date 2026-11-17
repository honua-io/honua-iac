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
    error_message = "Only the service role may bypass ownership tags for the named teardown actions."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : try(
      statement.Sid == "NamedTeardownFence" && statement.Effect == "Deny" &&
      toset(statement.Action) == toset(["events:RemoveTargets", "events:DeleteRule", "kms:DeleteAlias"]) &&
      toset(statement.NotResource) == toset([
        "arn:aws:events:us-east-1:000000000002:rule/honua-gate-*",
        "arn:aws:kms:us-east-1:000000000002:alias/honua-gate-*",
        "arn:aws:kms:us-east-1:000000000002:key/*"
      ]), false)
    ]) && aws_iam_role_policy_attachment.cloudformation_fences.role == aws_iam_role.cloudformation.name
    error_message = "An attached unconditional deny must fence teardown by exact service, account, region and gate prefix."
  }
  assert {
    condition = alltrue([for arn in [
      "arn:aws:events:us-east-1:000000000002:rule/honua-gate-synthetic-OpsAlarmEvents",
      "arn:aws:kms:us-east-1:000000000002:alias/honua-gate-synthetic-key",
      "arn:aws:kms:us-east-1:000000000002:key/synthetic-key"
      ] : anytrue([for pattern in local.named_teardown_deny.NotResource : can(regex("^${replace(pattern, "*", ".*")}$", arn))])]) && alltrue([
      for arn in [
        "arn:aws:events:us-east-1:000000000002:rule/foreign-rule",
        "arn:aws:kms:us-east-1:000000000002:alias/foreign-key",
        "arn:aws:events:us-east-1:000000000003:rule/honua-gate-foreign-account",
        "arn:aws:kms:us-west-2:000000000002:alias/honua-gate-foreign-region",
        "arn:aws:kms:us-east-1:000000000003:key/foreign-key",
        "arn:aws:rds:us-east-1:000000000002:subgrp:foreign-subnet-group",
        "arn:aws:rds:us-east-1:000000000003:subgrp:honua-gate-foreign-account",
        "arn:aws:rds:us-west-2:000000000002:subgrp:honua-gate-foreign-region",
        "arn:aws:rds:us-east-1:000000000002:db:honua-gate-database"
      ] : !anytrue([for pattern in local.named_teardown_deny.NotResource : can(regex("^${replace(pattern, "*", ".*")}$", arn))])
    ])
    error_message = "Gate names are eligible; foreign names, accounts and regions stay denied."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : try(
      statement.Sid == "AliasTeardownKeys" && statement.Effect == "Deny" &&
      statement.Action == "kms:DeleteAlias" &&
      statement.Resource == "arn:aws:kms:us-east-1:000000000002:key/*" &&
      statement.Condition.StringNotEqualsIfExists["aws:ResourceTag/HonuaGate"] == "true", false
    )])
    error_message = "Alias deletion must retain an attached ownership deny for untagged or foreign backing keys. StringNotEqualsIfExists denies missing and non-gate tags."
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
    condition     = alltrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : !contains(["NamedTeardownFence", "AliasTeardownKeys"], try(statement.Sid, ""))])
    error_message = "The service-role exception must not change the workload boundary."
  }
}

run "vault_storage_mount_is_service_role_only" {
  command = plan
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement : try(
      statement.Effect == "Allow" && statement.Resource == "*" && contains(statement.Action, "backup-storage:MountCapsule"), false)
    ]) && contains(local.service_role_ownership_deny.NotAction, "backup-storage:MountCapsule")
    error_message = "Vault creation requires the exact resource-less MountCapsule allow and ownership-deny exception."
  }
  assert {
    condition = alltrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(
      statement.Effect != "Allow" || !anytrue([for action in try(tolist(statement.Action), [statement.Action]) : startswith(action, "backup-storage:")]), true)
    ]) && !anytrue([for action in local.boundary_ownership_deny.NotAction : startswith(action, "backup-storage:")])
    error_message = "Workloads must receive neither a backup-storage allow nor an ownership exception."
  }
  assert {
    condition = alltrue([for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement : try(
      statement.Effect != "Allow" || alltrue([for action in try(tolist(statement.Action), [statement.Action]) : !startswith(action, "backup-storage:") || action == "backup-storage:MountCapsule"]), true)
    ]) && alltrue([for action in local.service_role_ownership_deny.NotAction : !startswith(action, "backup-storage:") || action == "backup-storage:MountCapsule"])
    error_message = "No storage content, deletion or wildcard permissions may accompany MountCapsule."
  }
}

run "subnet_cleanup_is_empty_by_default" {
  command = plan
  assert {
    condition     = !contains(local.service_role_ownership_deny.NotAction, "rds:DeleteDBSubnetGroup")
    error_message = "Untagged subnet deletion must never have a permanent gate-prefix exception."
  }
}
run "subnet_cleanup_is_one_exact_resource" {
  command = plan
  variables { temporary_cleanup_subnet_group_names = ["honua-gate-synthetic-databasesubnets-abc"] }
  assert {
    condition = contains(local.service_role_ownership_deny.NotAction, "rds:DeleteDBSubnetGroup") && anytrue([
      for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : try(
        statement.Sid == "TemporarySubnetCleanup" && statement.Effect == "Deny" &&
        statement.Action == "rds:DeleteDBSubnetGroup" &&
      statement.NotResource == ["arn:aws:rds:us-east-1:000000000002:subgrp:honua-gate-synthetic-databasesubnets-abc"], false)
    ])
    error_message = "Temporary cleanup must permit only the privately selected exact subnet group."
  }
}
run "subnet_cleanup_rejects_wildcard" {
  command = plan
  variables { temporary_cleanup_subnet_group_names = ["honua-gate-*"] }
  expect_failures = [var.temporary_cleanup_subnet_group_names]
}
run "subnet_cleanup_rejects_two_resources" {
  command = plan
  variables { temporary_cleanup_subnet_group_names = ["honua-gate-first", "honua-gate-second"] }
  expect_failures = [var.temporary_cleanup_subnet_group_names]
}
run "rds_creation_tags_are_name_and_tag_fenced" {
  command = plan
  assert {
    condition = (local.rds_creation_tag_deny.Condition.StringNotEqualsIfExists["aws:RequestTag/HonuaGate"] == "true" &&
      toset(local.rds_creation_name_deny.NotResource) == toset([
        for kind in ["subgrp", "db", "cluster", "pg", "og", "snapshot"] : "arn:aws:rds:us-east-1:000000000002:${kind}:honua-gate-*"
    ]))
    error_message = "New RDS resources need both the gate name in the gate account/region and HonuaGate=true."
  }
}

run "rds_tagging_authorization_scenarios" {
  command = plan
  assert {
    condition = alltrue([for scenario in [
      { arn = "arn:aws:rds:us-east-1:000000000002:subgrp:honua-gate-new", tag = "true", denied = false },
      { arn = "arn:aws:rds:us-east-1:000000000002:db:honua-gate-new", tag = "true", denied = false },
      { arn = "arn:aws:rds:us-east-1:000000000002:cluster:honua-gate-new", tag = "true", denied = false },
      { arn = "arn:aws:rds:us-east-1:000000000002:pg:honua-gate-new", tag = "true", denied = false },
      { arn = "arn:aws:rds:us-east-1:000000000002:og:honua-gate-new", tag = "true", denied = false },
      { arn = "arn:aws:rds:us-east-1:000000000002:snapshot:honua-gate-new", tag = "true", denied = false },
      { arn = "arn:aws:rds:us-east-1:000000000002:subgrp:foreign", tag = "true", denied = true },
      { arn = "arn:aws:rds:us-east-1:000000000003:subgrp:honua-gate-new", tag = "true", denied = true },
      { arn = "arn:aws:rds:us-west-2:000000000002:subgrp:honua-gate-new", tag = "true", denied = true },
      { arn = "arn:aws:rds:us-east-1:000000000002:subgrp:honua-gate-new", tag = "false", denied = true },
      { arn = "arn:aws:rds:us-east-1:000000000002:subgrp:honua-gate-new", tag = "", denied = true },
      { arn = "arn:aws:rds:us-east-1:000000000002:cluster-pg:honua-gate-new", tag = "true", denied = true }
      ] : scenario.denied == anytrue([
        for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : try(
          statement.Effect == "Deny" && contains(flatten([statement.Action]), "rds:AddTagsToResource") &&
          (try(statement.NotResource, null) == null || !anytrue([
            for pattern in statement.NotResource : can(regex("^${replace(pattern, "*", ".*")}$", scenario.arn))
          ])) &&
          alltrue([for operator, entries in try(statement.Condition, {}) : alltrue([
            for key, value in entries : operator == "StringNotEqualsIfExists" ?
            (key == "aws:RequestTag/HonuaGate" ? scenario.tag != value : true) :
            operator == "StringNotLikeIfExists" ? true : false
        ])]), false)
      ])
    ])
    error_message = "RDS tag-on-create requires the gate account, region, supported ARN kind, name and request tag together."
  }
}
