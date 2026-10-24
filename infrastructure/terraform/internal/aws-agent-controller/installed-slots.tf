# Exact optional allocations, reviewed with the immutable installed worker roots.
locals {
  has_installed_slots       = length(var.installed_worker_slots) > 0
  installed_lifecycle_roles = toset([for slot in var.installed_worker_slots : "arn:aws:iam::${var.account_id}:role/honua-agent-${slot.slot_id}-lifecycle"])
  installed_slot_keys       = [for slot in var.installed_worker_slots : "${var.candidate_digest}/runtime/${slot.runtime_id}/slot/${slot.slot_id}"]
  installed_retirement_keys = distinct([for slot in var.installed_worker_slots : "${var.candidate_digest}/runtime/${slot.runtime_id}/execution/execution-????????????????????????????????/retired"])
  static_claim_statements = [
    { Sid       = "RuntimeCanOnlyClaimOrObserve", Effect = "Deny", Principal = "*",
      NotAction = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:DescribeTable"],
      Resource  = aws_dynamodb_table.history["claims"].arn,
    Condition = { ArnNotEquals = { "aws:PrincipalArn" = sort(tolist(var.state_admin_role_arns)) } } },
    { Sid      = "OnlyFixedLifecycleRolesMayClaim", Effect = "Deny", Principal = "*", Action = "dynamodb:PutItem",
      Resource = aws_dynamodb_table.history["claims"].arn,
    Condition = { ArnNotEquals = { "aws:PrincipalArn" = sort(tolist(setunion(var.state_admin_role_arns, var.claim_writer_role_arns))) } } },
    # Only the fixed lifecycle may atomically claim the attempt/candidate and
    # record observed STOPPED. Its identity policy permits PutItem on exact keys.
    { Sid      = "OnlyFixedLifecycleMayTransactWrites", Effect = "Deny", Principal = "*", Action = "dynamodb:*",
      Resource = aws_dynamodb_table.history["claims"].arn,
      Condition = {
        ArnNotEquals = { "aws:PrincipalArn" = sort(tolist(setunion(var.state_admin_role_arns, var.claim_writer_role_arns))) }
        StringEquals = { "dynamodb:EnclosingOperation" = "TransactWriteItems" }
    } },
    { Sid      = "RuntimeCannotTransactReads", Effect = "Deny", Principal = "*", Action = "dynamodb:*",
      Resource = aws_dynamodb_table.history["claims"].arn,
      Condition = {
        ArnNotEquals = { "aws:PrincipalArn" = sort(tolist(var.state_admin_role_arns)) }
        StringEquals = { "dynamodb:EnclosingOperation" = "TransactGetItems" }
    } },
    { Sid      = "RuntimeClaimWritesMustBeTransactional", Effect = "Deny", Principal = "*", Action = "dynamodb:PutItem",
      Resource = aws_dynamodb_table.history["claims"].arn,
      Condition = {
        ArnNotEquals    = { "aws:PrincipalArn" = sort(tolist(var.state_admin_role_arns)) }
        StringNotEquals = { "dynamodb:EnclosingOperation" = "TransactWriteItems" }
    } }
  ]
  installed_claim_statements = concat([
    for index, statement in local.static_claim_statements : merge(statement,
      index == 0 ? { NotAction = concat(statement.NotAction, ["dynamodb:UpdateItem"]) } : {},
      contains([1, 2], index) ? { Condition = merge(statement.Condition, {
        ArnNotEquals = { "aws:PrincipalArn" = sort(tolist(setunion(var.state_admin_role_arns, var.claim_writer_role_arns, local.runtime_principals))) }
    }) } : {})
    ], [
    { Sid      = "OnlyInstalledPrincipalsMayUpdateSlots", Effect = "Deny", Principal = "*", Action = "dynamodb:UpdateItem",
      Resource = aws_dynamodb_table.history["claims"].arn,
    Condition = { ArnNotEquals = { "aws:PrincipalArn" = sort(tolist(setunion(var.state_admin_role_arns, local.installed_lifecycle_roles, local.runtime_principals))) } } },
    { Sid      = "SlotUpdatesMustBeTransactional", Effect = "Deny", Principal = "*", Action = "dynamodb:UpdateItem",
      Resource = aws_dynamodb_table.history["claims"].arn,
      Condition = { ArnNotEquals = { "aws:PrincipalArn" = sort(tolist(var.state_admin_role_arns)) },
    StringNotEquals = { "dynamodb:EnclosingOperation" = "TransactWriteItems" } } },
    { Sid      = "ControllerWritesOnlyInstalledRetirementKeys", Effect = "Deny", Principal = "*", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem"],
      Resource = aws_dynamodb_table.history["claims"].arn,
      Condition = { ArnEquals = { "aws:PrincipalArn" = sort(tolist(local.runtime_principals)) },
    "ForAnyValue:StringNotLike" = { "dynamodb:LeadingKeys" = concat(local.installed_slot_keys, local.installed_retirement_keys) } } }
    ], [for controller in var.installed_runtime_controllers : {
      Sid      = "InstalledController${index(var.installed_runtime_controllers, controller)}OwnRuntimeOnly", Effect = "Deny", Principal = "*", Action = ["dynamodb:PutItem", "dynamodb:UpdateItem"],
      Resource = aws_dynamodb_table.history["claims"].arn,
      Condition = { ArnEquals = { "aws:PrincipalArn" = controller.role_arn },
        "ForAnyValue:StringNotLike" = { "dynamodb:LeadingKeys" = concat(
          [for slot in var.installed_worker_slots : "${var.candidate_digest}/runtime/${slot.runtime_id}/slot/${slot.slot_id}" if slot.runtime_id == controller.runtime_id],
          ["${var.candidate_digest}/runtime/${controller.runtime_id}/execution/execution-????????????????????????????????/retired"]
      ) } }
      }], [for controller in var.installed_runtime_controllers : {
      Sid      = "InstalledController${index(var.installed_runtime_controllers, controller)}ReadsOwnRuntimeOnly", Effect = "Deny", Principal = "*", Action = "dynamodb:GetItem",
      Resource = aws_dynamodb_table.history["claims"].arn,
      Condition = { ArnEquals = { "aws:PrincipalArn" = controller.role_arn },
        "ForAnyValue:StringNotLike" = { "dynamodb:LeadingKeys" = concat(
          [for slot in var.installed_worker_slots : "${var.candidate_digest}/runtime/${slot.runtime_id}/slot/${slot.slot_id}" if slot.runtime_id == controller.runtime_id],
          [for suffix in ["", "/launched", "/stopped", "/retired"] : "${var.candidate_digest}/runtime/${controller.runtime_id}/execution/execution-????????????????????????????????${suffix}"]
      ) } }
      }], [for slot in var.installed_worker_slots : {
      Sid      = "Slot${index(var.installed_worker_slots, slot)}LifecycleUpdatesOnlyOwnSlot", Effect = "Deny", Principal = "*", Action = "dynamodb:UpdateItem",
      Resource = aws_dynamodb_table.history["claims"].arn,
      Condition = { ArnEquals = { "aws:PrincipalArn" = "arn:aws:iam::${var.account_id}:role/honua-agent-${slot.slot_id}-lifecycle" },
      "ForAnyValue:StringNotEquals" = { "dynamodb:LeadingKeys" = ["${var.candidate_digest}/runtime/${slot.runtime_id}/slot/${slot.slot_id}"] } }
  }])
}
