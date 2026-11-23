# Synthetic fixtures only; deployment identifiers come from private SSM configuration.
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
  member_account_id   = format("%012d", 2)
  lane_principal_arns = [format("arn:aws:iam::%s:role/GateOperator", format("%012d", 1))]
}

run "template_bucket_is_private_versioned_and_expiring" {
  command = plan
  assert {
    condition     = aws_s3_bucket.templates.bucket == format("honua-gate-templates-%s", var.member_account_id) && output.template_bucket_name == aws_s3_bucket.templates.bucket
    error_message = "The template bucket is named per account and exported."
  }
  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.templates.block_public_acls,
      aws_s3_bucket_public_access_block.templates.block_public_policy,
      aws_s3_bucket_public_access_block.templates.ignore_public_acls,
      aws_s3_bucket_public_access_block.templates.restrict_public_buckets
    ]) && one(aws_s3_bucket_ownership_controls.templates.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "Templates must never be publicly readable or ACL-shared."
  }
  assert {
    condition     = one(aws_s3_bucket_versioning.templates.versioning_configuration).status == "Enabled"
    error_message = "Template uploads must be versioned."
  }
  assert {
    condition = anytrue([
      for rule in aws_s3_bucket_server_side_encryption_configuration.templates.rule :
      one(rule.apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    ])
    error_message = "Templates use Amazon S3 managed keys (SSE-S3), which need no KMS grant through the lane boundary or the shared-account content fence."
  }
  assert {
    condition = anytrue([
      for rule in aws_s3_bucket_lifecycle_configuration.templates.rule :
      rule.status == "Enabled" && one(rule.expiration).days == 14 && one(rule.noncurrent_version_expiration).noncurrent_days == 14 && one(rule.abort_incomplete_multipart_upload).days_after_initiation == 1
    ])
    error_message = "Current and noncurrent template versions expire after 14 days."
  }
}

run "lane_writes_and_reads_templates_only" {
  command = plan
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement :
      try(statement.Sid == "GateTemplates" && statement.Effect == "Allow" && toset(statement.Action) == toset(["s3:PutObject", "s3:GetObject"]) && statement.Resource == format("arn:aws:s3:::honua-gate-templates-%s/templates/*", var.member_account_id) && statement.Condition.StringEquals["aws:ResourceAccount"] == var.member_account_id, false)
    ]) && aws_iam_policy.lane_boundary.policy == aws_iam_role_policy.lane.policy
    error_message = "The lane may put and get template objects only in its own account, and its boundary allows the same."
  }
  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement :
      statement.Effect != "Allow" || !anytrue([for action in flatten([statement.Action]) : startswith(action, "s3:") && !contains(["s3:PutObject", "s3:GetObject"], action)])
    ])
    error_message = "The lane gets no other S3 action, including bucket deletion or policy changes."
  }
}

run "cloudformation_reads_templates_and_workloads_cannot_touch_them" {
  command = plan
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement :
      try(statement.Sid == "ReadGateTemplates" && statement.Effect == "Allow" && statement.Action == "s3:GetObject" && statement.Resource == format("arn:aws:s3:::honua-gate-templates-%s/templates/*", var.member_account_id), false)
    ])
    error_message = "CloudFormation reads uploaded templates."
  }
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_s3_bucket_policy.templates.policy).Statement :
      try(statement.Sid == "OnlyCloudFormationReads" && statement.Effect == "Deny" && statement.NotAction == "s3:GetObject" && statement.Condition.ArnEquals["aws:PrincipalArn"] == local.service_role_arn && toset(statement.Resource) == toset([local.template_bucket_arn, "${local.template_bucket_arn}/*"]), false)
    ])
    error_message = "The service role's s3:* on honua-gate-* must not let a template rewrite, delete or re-policy the template bucket."
  }
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_s3_bucket_policy.templates.policy).Statement :
      try(statement.Sid == "NoWorkloadAccess" && statement.Effect == "Deny" && statement.NotAction == "s3:GetObject" && statement.Condition.ArnLike["aws:PrincipalArn"] == local.workload_roles && toset(statement.Resource) == toset([local.template_bucket_arn, "${local.template_bucket_arn}/*"]), false)
    ])
    error_message = "Launch Stack workload roles must not change, list or re-policy templates."
  }
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_s3_bucket_policy.templates.policy).Statement :
      try(statement.Sid == "WorkloadsReadOnlyInstallArchives" && statement.Effect == "Deny" && statement.Action == "s3:GetObject" && statement.Condition.ArnLike["aws:PrincipalArn"] == local.workload_roles && statement.NotResource == [format("arn:aws:s3:::honua-gate-templates-%s/templates/*/console.zip", var.member_account_id), format("arn:aws:s3:::honua-gate-templates-%s/templates/*/watchdog.zip", var.member_account_id)], false)
    ])
    error_message = "Launch Stack workload roles may read published Console bundles and no other template object."
  }
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_s3_bucket_policy.templates.policy).Statement :
      try(statement.Sid == "TlsOnly" && statement.Effect == "Deny" && statement.Condition.Bool["aws:SecureTransport"] == "false", false)
    ])
    error_message = "Template transfers require TLS."
  }
}

run "shared_account_fences_leave_template_objects_reachable" {
  command = plan
  variables {
    shared_account          = true
    protected_state_buckets = [for index in range(2) : format("synthetic-state-%047d", index)]
    protected_ssm_paths     = [for index in range(18) : format("/synthetic/gate/runtime/protected-parameter-%02d", index)]
    budget_alert_email      = "gate@example.invalid"
  }
  assert {
    condition = alltrue([
      for policy in [aws_iam_role_policy.lane.policy, aws_iam_role_policy.cloudformation.policy] : alltrue([
        for statement in jsondecode(policy).Statement : !(statement.Effect == "Deny" && contains(flatten([try(statement.Action, [])]), "s3:*")) || (
          !anytrue([for pattern in flatten([try(statement.Resource, [])]) : can(regex("^${replace(pattern, "*", ".*")}$", "${local.template_bucket_arn}/templates/synthetic.json"))]) &&
          (anytrue([for pattern in flatten([try(statement.NotResource, "*")]) : can(regex("^${replace(pattern, "*", ".*")}$", "${local.template_bucket_arn}/templates/synthetic.json"))]))
        )
      ])
    ])
    error_message = "Shared-account bucket fences must not deny the template objects."
  }
  assert {
    condition     = contains(local.service_role_ownership_deny.NotAction, "s3:*") && contains(local.boundary_ownership_deny.NotAction, "s3:*")
    error_message = "The stack-ownership NotAction fence must keep exempting S3, which is fenced by bucket name and the template bucket policy."
  }
}
