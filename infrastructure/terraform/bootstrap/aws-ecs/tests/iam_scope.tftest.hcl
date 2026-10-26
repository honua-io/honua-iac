# IAM scope of the local-only ECS bootstrap user.
#
# The policy documents are rendered by the real AWS provider (a local
# computation), with fake static credentials and every account lookup
# overridden, so the plan never reaches AWS. Nothing is applied.

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

override_data {
  target = data.aws_partition.current
  values = {
    partition  = "aws"
    dns_suffix = "amazonaws.com"
  }
}

run "iam_is_prefix_scoped_and_bounded" {
  command = plan

  variables {
    workload_name_prefix = "honuaecs"
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(data.aws_iam_policy_document.iam.json).Statement :
      !contains(flatten([statement.Action]), "iam:PassRole") || statement.Effect == "Deny" || flatten([statement.Resource]) != ["*"]
    ])
    error_message = "No Allow statement may grant iam:PassRole on Resource \"*\"."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(data.aws_iam_policy_document.terraform.json).Statement :
      length([for action in flatten([statement.Action]) : action if startswith(action, "iam:")]) == 0
    ])
    error_message = "The service policy must not grant any IAM action; IAM lives only in the scoped -iam policy."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(data.aws_iam_policy_document.iam.json).Statement :
      statement.Effect == "Deny" || length(setintersection(toset(flatten([statement.Action])), toset([
        "iam:AttachRolePolicy", "iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:CreateRole",
        "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:DetachRolePolicy", "iam:PassRole",
        "iam:PutRolePermissionsBoundary", "iam:PutRolePolicy",
        ]))) == 0 || alltrue([
        for resource in flatten([statement.Resource]) :
        startswith(resource, "arn:aws:iam::123456789012:role/honuaecs") || startswith(resource, "arn:aws:iam::123456789012:policy/honuaecs")
      ])
    ])
    error_message = "IAM mutation and PassRole must be confined to role/honuaecs* and policy/honuaecs*."
  }

  assert {
    condition = one([
      for statement in jsondecode(data.aws_iam_policy_document.iam.json).Statement :
      statement.Condition.StringEquals["iam:PermissionsBoundary"] if try(statement.Sid, "") == "CreateBoundedWorkloadRoles"
    ]) == "arn:aws:iam::123456789012:policy/honua-local-unsupported-dev-workload-boundary"
    error_message = "CreateRole and role-policy edits must require the workload permissions boundary."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(data.aws_iam_policy_document.iam.json).Statement :
      !contains(flatten([statement.Action]), "iam:CreateRole") || try(statement.Condition.StringEquals["iam:PermissionsBoundary"], "") != ""
    ])
    error_message = "Every statement granting iam:CreateRole must carry an iam:PermissionsBoundary condition."
  }

  assert {
    condition = one([
      for statement in jsondecode(data.aws_iam_policy_document.iam.json).Statement :
      statement.Condition.StringEquals["iam:PassedToService"] if try(statement.Sid, "") == "PassWorkloadRolesToEcsTasksOnly"
    ]) == "ecs-tasks.amazonaws.com"
    error_message = "PassRole must be limited to ecs-tasks.amazonaws.com."
  }

  assert {
    condition = length(setsubtract(
      toset(["DenyLongLivedCredentials", "DenyRoleChaining", "DenyPassingPrivilegedRoles", "DenyDeploymentIdentityMutation", "DenyBoundaryRemoval"]),
      toset([for statement in jsondecode(data.aws_iam_policy_document.iam.json).Statement : try(statement.Sid, "") if statement.Effect == "Deny"])
    )) == 0
    error_message = "The aws-exec-identity separation denials must be present."
  }

  assert {
    condition = alltrue([
      for arn in [
        "arn:aws:iam::123456789012:policy/honua-local-unsupported-dev-policy",
        "arn:aws:iam::123456789012:policy/honua-local-unsupported-dev-iam",
        "arn:aws:iam::123456789012:policy/honua-local-unsupported-dev-workload-boundary",
        ] : contains(flatten([one([
          for statement in jsondecode(data.aws_iam_policy_document.iam.json).Statement :
          statement.Resource if try(statement.Sid, "") == "DenyDeploymentIdentityMutation"
      ])]), arn)
    ])
    error_message = "The deploy user's own policy and the workload boundary must be immutable to it."
  }

  assert {
    condition = alltrue([
      for json in [
        data.aws_iam_policy_document.terraform.minified_json,
        data.aws_iam_policy_document.iam.minified_json,
        data.aws_iam_policy_document.workload_boundary.minified_json,
      ] : length(json) <= 6144
    ])
    error_message = "Every managed policy must fit the 6144-character IAM quota."
  }

  assert {
    condition = alltrue([
      for action in ["iam:*", "sts:AssumeRole", "organizations:*"] :
      contains(one([
        for statement in jsondecode(data.aws_iam_policy_document.workload_boundary.json).Statement :
        statement.NotAction if try(statement.Sid, "") == "WorkloadServiceCeiling"
      ]), action)
    ])
    error_message = "The workload boundary must exclude IAM, Organizations and role assumption."
  }
}

run "rejects_wildcard_workload_prefix" {
  command = plan

  variables {
    workload_name_prefix = "*"
  }

  expect_failures = [var.workload_name_prefix]
}
