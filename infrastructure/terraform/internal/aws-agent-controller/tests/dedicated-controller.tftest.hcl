mock_provider "aws" {}
override_resource {
  target = aws_dynamodb_table.history["state"]
  values = { arn = "arn:aws:dynamodb:us-east-1:123456789012:table/fixture-state", name = "fixture-state" }
}
override_resource {
  target = aws_dynamodb_table.history["claims"]
  values = { arn = "arn:aws:dynamodb:us-east-1:123456789012:table/fixture-claims", name = "fixture-claims" }
}
variables {
  region                        = "us-east-1"
  account_id                    = "123456789012"
  candidate_digest              = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  controller_role_arn           = "arn:aws:iam::123456789012:role/controller/runtime"
  state_admin_role_arns         = ["arn:aws:iam::123456789012:role/state-deployer"]
  claim_writer_role_arns        = ["arn:aws:iam::123456789012:role/honua-agent-fixed-slot-lifecycle", "arn:aws:iam::123456789012:role/honua-agent-other-slot-lifecycle"]
  installed_worker_slots        = [{ runtime_id = "runtime_01", slot_id = "fixed-slot" }, { runtime_id = "runtime_02", slot_id = "other-slot" }]
  installed_runtime_controllers = [{ runtime_id = "runtime_01", role_arn = "arn:aws:iam::123456789012:role/controller/poller" }]
}
run "dedicated_poller_keeps_runtime_fences" {
  command = apply
  assert {
    condition     = !contains(var.state_admin_role_arns, var.installed_runtime_controllers[0].role_arn) && !contains(var.claim_writer_role_arns, var.installed_runtime_controllers[0].role_arn) && contains(jsondecode(aws_s3_bucket_policy.state.policy).Statement[3].Condition.ArnEquals["aws:PrincipalArn"], var.installed_runtime_controllers[0].role_arn) && contains(jsondecode(aws_dynamodb_resource_policy.state.policy).Statement[1].Condition.ArnEquals["aws:PrincipalArn"], var.installed_runtime_controllers[0].role_arn)
    error_message = "The dedicated poller must receive runtime retention restrictions without administrator or lifecycle status."
  }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.state.policy).Statement[4].Action == "s3:PutObject" && jsondecode(aws_s3_bucket_policy.state.policy).Statement[4].Resource == ["${local.bucket_arn}/${local.state_prefix}initialization.json", "${local.bucket_arn}/${local.state_prefix}installed-controllers/*", "${local.bucket_arn}/${local.state_prefix}installed-workers/*"] && jsondecode(aws_s3_bucket_policy.state.policy).Statement[4].Condition.ArnEquals["aws:PrincipalArn"] == [var.installed_runtime_controllers[0].role_arn]
    error_message = "Poller state writes must not forge installation/identity originals or initialize another accounting generation."
  }
  assert {
    condition     = aws_iam_role_policy.installed_controller_state[var.installed_runtime_controllers[0].role_arn].role == "poller" && aws_iam_role_policy.installed_controller_state[var.installed_runtime_controllers[0].role_arn].policy == aws_iam_role_policy.controller_state.policy && jsondecode(aws_iam_role_policy.controller_state.policy).Statement[4].Condition["ForAllValues:StringEquals"]["dynamodb:LeadingKeys"] == [var.candidate_digest] && jsondecode(aws_iam_role_policy.controller_state.policy).Statement[6].Condition.StringEquals["dynamodb:EnclosingOperation"] == "TransactWriteItems"
    error_message = "Additional state policies must preserve exact candidate fencing and transaction-only original-head checks."
  }
  assert {
    condition     = [for s in jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement : s.Condition["ForAnyValue:StringNotLike"]["dynamodb:LeadingKeys"] if s.Sid == "InstalledController0OwnRuntimeOnly"][0] == ["${var.candidate_digest}/runtime/runtime_01/slot/fixed-slot", "${var.candidate_digest}/runtime/runtime_01/execution/execution-????????????????????????????????", "${var.candidate_digest}/runtime/runtime_01/execution/execution-????????????????????????????????/retired"] && jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[6].Condition.StringNotEquals["dynamodb:EnclosingOperation"] == "TransactWriteItems" && alltrue([for s in jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement : s.Effect == "Deny"])
    error_message = "A poller must not read or retire another runtime's claims, bypass transactions or gain resource-policy Allow authority."
  }
}
run "reject_poller_admin_overlap" {
  command = plan
  variables { installed_runtime_controllers = [{ runtime_id = "runtime_01", role_arn = "arn:aws:iam::123456789012:role/state-deployer" }] }
  expect_failures = [aws_s3_bucket.state]
}
run "reject_poller_lifecycle_overlap" {
  command = plan
  variables { installed_runtime_controllers = [{ runtime_id = "runtime_01", role_arn = "arn:aws:iam::123456789012:role/honua-agent-fixed-slot-lifecycle" }] }
  expect_failures = [aws_s3_bucket.state]
}
run "reject_foreign_poller" {
  command = plan
  variables { installed_runtime_controllers = [{ runtime_id = "runtime_01", role_arn = "arn:aws:iam::999999999999:role/controller/poller" }] }
  expect_failures = [aws_s3_bucket.state]
}
run "reject_unallocated_runtime" {
  command = plan
  variables { installed_runtime_controllers = [{ runtime_id = "not-installed", role_arn = "arn:aws:iam::123456789012:role/controller/poller" }] }
  expect_failures = [aws_s3_bucket.state]
}
run "reject_legacy_controller_relabeling" {
  command = plan
  variables { installed_runtime_controllers = [{ runtime_id = "runtime_01", role_arn = "arn:aws:iam::123456789012:role/controller/runtime" }] }
  expect_failures = [aws_s3_bucket.state]
}
run "reject_wildcard_poller" {
  command = plan
  variables { installed_runtime_controllers = [{ runtime_id = "runtime_01", role_arn = "arn:aws:iam::123456789012:role/controller/*" }] }
  expect_failures = [var.installed_runtime_controllers]
}
