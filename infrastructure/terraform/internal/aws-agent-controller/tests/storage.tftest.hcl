mock_provider "aws" {
  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-1:123456789012:table/fixture" }
  }
}

variables {
  region                 = "us-east-1"
  account_id             = "123456789012"
  candidate_digest       = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  controller_role_arn    = "arn:aws:iam::123456789012:role/controller/runtime"
  state_admin_role_arns  = ["arn:aws:iam::123456789012:role/state-deployer"]
  claim_writer_role_arns = ["arn:aws:iam::123456789012:role/honua-agent-fixture-attempt-lifecycle"]
}

run "retained_candidate_storage" {
  command = apply
  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled" && !aws_s3_bucket.state.force_destroy && aws_s3_bucket_ownership_controls.state.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "Evidence requires retained versions, owner enforcement and no force deletion."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls && aws_s3_bucket_public_access_block.state.block_public_policy && aws_s3_bucket_public_access_block.state.ignore_public_acls && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    error_message = "Controller evidence must never be public."
  }
  assert {
    condition     = alltrue([for table in aws_dynamodb_table.history : table.deletion_protection_enabled && table.point_in_time_recovery[0].enabled && table.server_side_encryption[0].enabled && table.hash_key == "candidateKey"]) && aws_dynamodb_table.history["state"].name != aws_dynamodb_table.history["claims"].name
    error_message = "Accounting and launch claims require separate protected, recoverable tables."
  }
  assert {
    condition     = toset(jsondecode(aws_s3_bucket_policy.state.policy).Statement[1].Condition.ArnNotEquals["aws:PrincipalArn"]) == toset(local.state_principals) && length(local.state_principals) == 2
    error_message = "Workers and unrelated principals must be explicitly excluded from private state."
  }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.state.policy).Statement[2].Effect == "Deny" && jsondecode(aws_s3_bucket_policy.state.policy).Statement[2].Condition.StringNotEquals["s3:if-none-match"] == "*"
    error_message = "Every object write must be conditional create-only, including initialization."
  }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.state.policy).Statement[3].Effect == "Deny" && !contains(jsondecode(aws_s3_bucket_policy.state.policy).Statement[3].NotAction, "s3:DeleteObjectVersion") && !contains(jsondecode(aws_s3_bucket_policy.state.policy).Statement[3].NotAction, "s3:PutLifecycleConfiguration")
    error_message = "A runtime role must not erase history or weaken retention even through another identity policy."
  }
  assert {
    condition     = jsondecode(aws_dynamodb_resource_policy.state.policy).Statement[1].NotAction == ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:DescribeTable"] && jsondecode(aws_iam_role_policy.controller_state.policy).Statement[4].Condition["ForAllValues:StringEquals"]["dynamodb:LeadingKeys"] == [var.candidate_digest]
    error_message = "Runtime state authority must exclude head deletion and bind the exact candidate key."
  }
  assert {
    condition     = jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[0].NotAction == ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:DescribeTable"] && toset(jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[0].Condition.ArnNotEquals["aws:PrincipalArn"]) == var.state_admin_role_arns
    error_message = "Runtime roles must not erase launch claims or change PITR, TTL, policy or table settings."
  }
  assert {
    condition     = toset(jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[1].Condition.ArnNotEquals["aws:PrincipalArn"]) == setunion(var.state_admin_role_arns, var.claim_writer_role_arns) && jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[2].Condition.StringEquals["dynamodb:EnclosingOperation"] == "TransactWriteItems" && toset(jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[2].Condition.ArnNotEquals["aws:PrincipalArn"]) == setunion(var.state_admin_role_arns, var.claim_writer_role_arns) && jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[3].Condition.StringEquals["dynamodb:EnclosingOperation"] == "TransactGetItems" && toset(jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[3].Condition.ArnNotEquals["aws:PrincipalArn"]) == var.state_admin_role_arns
    error_message = "Only the fixed lifecycle may put claims, and transaction APIs must not bypass this restriction."
  }
  assert {
    condition     = aws_iam_role_policy.controller_state.role == "runtime" && jsondecode(aws_iam_role_policy.controller_state.policy).Statement[3].Condition.StringEquals["s3:if-none-match"] == "*" && output.state_config.table == aws_dynamodb_table.history["state"].name
    error_message = "Role paths and controller state outputs must match the actual runtime contract."
  }
}

run "reject_worker_account_as_controller" {
  command = plan
  variables {
    controller_role_arn = "arn:aws:iam::999999999999:role/controller"
  }
  expect_failures = [aws_s3_bucket.state]
}

run "reject_combined_runtime_admin_custody" {
  command = plan
  variables {
    state_admin_role_arns = ["arn:aws:iam::123456789012:role/controller/runtime"]
  }
  expect_failures = [aws_s3_bucket.state]
}

run "reject_wildcard_recovery_authority" {
  command = plan
  variables {
    state_admin_role_arns = ["arn:aws:iam::123456789012:role/*"]
  }
  expect_failures = [var.state_admin_role_arns]
}

run "reject_foreign_claim_writer" {
  command = plan
  variables {
    claim_writer_role_arns = ["arn:aws:iam::999999999999:role/honua-agent-fixture-attempt-lifecycle"]
  }
  expect_failures = [aws_s3_bucket.state]
}

run "reject_agent_worker_as_claim_writer" {
  command = plan
  variables {
    claim_writer_role_arns = ["arn:aws:iam::123456789012:role/honua-agent-fixture-attempt-worker"]
  }
  expect_failures = [var.claim_writer_role_arns]
}

run "default_disables_runtime_claims" {
  command = apply
  variables {
    claim_writer_role_arns = []
  }
  assert {
    condition     = toset(jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[1].Condition.ArnNotEquals["aws:PrincipalArn"]) == var.state_admin_role_arns
    error_message = "No lifecycle writes may occur until its exact role is reviewed and configured."
  }
}
