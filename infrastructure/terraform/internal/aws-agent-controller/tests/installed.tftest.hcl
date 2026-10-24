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
  claim_writer_role_arns = ["arn:aws:iam::123456789012:role/honua-agent-fixed-slot-lifecycle"]
  installed_worker_slots = [{ runtime_id = "runtime_01", slot_id = "fixed-slot" }]
}
run "installed_retirement_policy" {
  command = apply
  assert {
    condition     = contains(jsondecode(aws_dynamodb_resource_policy.state.policy).Statement[1].NotAction, "dynamodb:ConditionCheckItem") && jsondecode(aws_iam_role_policy.controller_state.policy).Statement[6].Action == "dynamodb:ConditionCheckItem" && jsondecode(aws_iam_role_policy.controller_state.policy).Statement[6].Resource == aws_dynamodb_table.history["state"].arn && jsondecode(aws_iam_role_policy.controller_state.policy).Statement[6].Condition["ForAllValues:StringEquals"]["dynamodb:LeadingKeys"] == [var.candidate_digest] && jsondecode(aws_iam_role_policy.controller_state.policy).Statement[6].Condition.StringEquals["dynamodb:EnclosingOperation"] == "TransactWriteItems"
    error_message = "Retirement must fence the actual candidate state head in the original state table, only inside its transaction."
  }
  assert {
    condition     = contains(jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[0].NotAction, "dynamodb:UpdateItem") && toset(jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[5].Condition.ArnNotEquals["aws:PrincipalArn"]) == setunion(var.state_admin_role_arns, var.claim_writer_role_arns, [var.controller_role_arn]) && jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[6].Condition.StringNotEquals["dynamodb:EnclosingOperation"] == "TransactWriteItems"
    error_message = "Only the exact installed controller/lifecycle may update slots, and direct nontransactional updates remain denied."
  }
  assert {
    condition     = jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[7].Condition["ForAnyValue:StringNotLike"]["dynamodb:LeadingKeys"] == ["${var.candidate_digest}/runtime/runtime_01/slot/fixed-slot", "${var.candidate_digest}/runtime/runtime_01/execution/execution-????????????????????????????????/retired"] && jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[8].Condition["ForAnyValue:StringNotEquals"]["dynamodb:LeadingKeys"] == ["${var.candidate_digest}/runtime/runtime_01/slot/fixed-slot"]
    error_message = "Controller writes and lifecycle updates must remain inside the reviewed exact slot and permanent retirement namespaces."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement : statement.Effect == "Deny"]) && !contains(jsondecode(aws_dynamodb_resource_policy.claims.policy).Statement[0].NotAction, "dynamodb:DeleteItem") && strcontains(aws_dynamodb_resource_policy.claims.policy, "RuntimeClaimWritesMustBeTransactional")
    error_message = "No resource policy may grant authority, permit claim deletion or remove the existing permanent transactional claim guard."
  }
}
run "reject_unregistered_installed_lifecycle" {
  command = plan
  variables {
    installed_worker_slots = [{ runtime_id = "runtime_01", slot_id = "unregistered-slot" }]
  }
  expect_failures = [aws_s3_bucket.state]
}
run "reject_duplicate_physical_slots" {
  command = plan
  variables {
    installed_worker_slots = [{ runtime_id = "runtime_01", slot_id = "fixed-slot" }, { runtime_id = "runtime_02", slot_id = "fixed-slot" }]
  }
  expect_failures = [var.installed_worker_slots]
}
