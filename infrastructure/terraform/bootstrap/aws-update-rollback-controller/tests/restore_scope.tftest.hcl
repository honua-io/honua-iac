# Restore scope of the update/rollback controller.
#
# Policies are rendered locally. Fake static credentials and an overridden
# caller identity keep the plan off AWS. Nothing is applied.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/terraform-test"
    user_id    = "AIDATEST"
  }
}

run "default_prefix_can_restore_its_own_cell" {
  command = plan

  assert {
    condition = anytrue([
      for statement in jsondecode(data.aws_iam_policy_document.floor.json).Statement :
      statement.Effect == "Allow" && contains(flatten([statement.Action]), "rds:RestoreDBInstanceFromDBSnapshot") && anytrue([
        for resource in try(flatten([statement.Resource]), []) : strcontains(resource, ":db:honua-cert-")
      ])
    ])
    error_message = "The floor must allow snapshot restore of honua-cert- databases."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(data.aws_iam_policy_document.boundary.json).Statement :
      statement.Effect != "Allow" || !contains(flatten([statement.Action]), "rds:RestoreDBInstanceFromDBSnapshot") || alltrue([
        for resource in try(flatten([statement.Resource]), []) :
        strcontains(resource, "honua-cert-") && !strcontains(resource, "honua-certrun") && !strcontains(resource, ":db:other")
      ])
    ])
    error_message = "Restore allows must stay on the honua-cert- prefix and must not name honua-certrun."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(data.aws_iam_policy_document.boundary.json).Statement :
      try(statement.Sid, "") == "NeverStandingResources" && anytrue([
        for resource in try(flatten([statement.NotResource]), []) : strcontains(resource, ":service/honua-cert-")
      ])
    ])
    error_message = "The cert/demo deny must exempt the cell's own ECS service ARNs so the per-cell canary grant still works."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(data.aws_iam_policy_document.boundary.json).Statement :
      contains(flatten([statement.Action]), "ecs:UpdateService") && statement.Effect == "Allow"
    ])
    error_message = "The boundary must still allow ecs:UpdateService for the per-cell recovery grant."
  }

  assert {
    condition = alltrue([
      for document in [
        jsondecode(data.aws_iam_policy_document.boundary.json),
        jsondecode(data.aws_iam_policy_document.floor.json),
        ] : anytrue([
          for statement in document.Statement :
          statement.Effect == "Deny" && contains(flatten([statement.Action]), "rds:DeleteDBInstance")
      ])
    ])
    error_message = "Boundary and floor must deny deleting a restored instance."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(data.aws_iam_policy_document.floor.json).Statement :
      try(statement.Sid, "") == "CellLambdaAliasSwitch" && anytrue([
        for resource in try(flatten([statement.Resource]), []) : strcontains(resource, ":function:honua-cert-")
      ])
    ])
    error_message = "The floor Lambda grant must include the restore prefix so a cert-cell alias switch is not only a boundary exception."
  }
}

run "empty_prefixes_grant_no_restore" {
  command = plan

  variables {
    restore_name_prefixes = []
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(data.aws_iam_policy_document.floor.json).Statement :
      statement.Effect != "Allow" || !contains(flatten([statement.Action]), "rds:RestoreDBInstanceFromDBSnapshot")
    ])
    error_message = "An empty restore prefix list must not allow RDS restore."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(data.aws_iam_policy_document.boundary.json).Statement :
      try(statement.Sid, "") == "NeverStandingResources" && !can(statement.NotResource) && (
        try(statement.Resource, "") == "*" || try(statement.Resource[0], "") == "*"
      )
    ])
    error_message = "An empty restore prefix list must keep the blanket cert/demo deny."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(data.aws_iam_policy_document.floor.json).Statement :
      try(statement.Sid, "") != "CellLambdaAliasSwitch" || alltrue([
        for resource in try(flatten([statement.Resource]), []) : !strcontains(resource, "honua-cert-")
      ])
    ])
    error_message = "Empty restore prefixes must not add honua-cert- to the Lambda floor."
  }
}

run "prefix_without_trailing_hyphen_is_rejected" {
  command = plan

  variables {
    restore_name_prefixes = ["honua-cert"]
  }

  expect_failures = [
    var.restore_name_prefixes,
  ]
}
