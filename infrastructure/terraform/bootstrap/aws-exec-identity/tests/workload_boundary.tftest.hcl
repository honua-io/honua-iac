# The deployment role must not mint an unbounded honua-* role. The AWS
# provider renders the policy documents locally; override_data supplies the
# account and partition so the test does not call AWS.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
}

override_data {
  target          = data.aws_caller_identity.current
  override_during = plan
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/terraform-test"
    user_id    = "AIDATEST"
  }
}

override_data {
  target          = data.aws_partition.current
  override_during = plan
  values = {
    dns_suffix         = "amazonaws.com"
    id                 = "aws"
    partition          = "aws"
    reverse_dns_prefix = "com.amazonaws"
  }
}

variables {
  state_bucket_arn  = "arn:aws:s3:::honua-tfstate-test"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  oidc_provider_url = "https://token.actions.githubusercontent.com"
  oidc_subjects     = ["repo:honua-io/honua-iac:environment:prod"]
}

run "created_roles_require_the_boundary" {
  command = plan

  assert {
    condition     = output.execution_identity_contract.separation.workload_boundary_required == true
    error_message = "The identity contract must record that a workload boundary is required."
  }

  assert {
    condition = one([
      for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
      if statement.Sid == "CreateBoundedWorkloadRoles"
    ]).Condition.StringEquals["iam:PermissionsBoundary"] == "arn:aws:iam::123456789012:policy/honua-prod-workload-boundary"
    error_message = "CreateRole must require the workload permissions boundary."
  }

  assert {
    condition = (
      one([
        for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
        if statement.Sid == "AttachBoundedWorkloadPolicies"
      ]).Condition.StringEquals["iam:PermissionsBoundary"] == "arn:aws:iam::123456789012:policy/honua-prod-workload-boundary"
      && !anytrue([
        for arn in flatten([one([
          for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
          if statement.Sid == "AttachBoundedWorkloadPolicies"
        ]).Condition.ArnLike["iam:PolicyARN"]]) : strcontains(arn, "AdministratorAccess")
      ])
    )
    error_message = "AttachRolePolicy must require the boundary and must not allow AdministratorAccess."
  }

  assert {
    condition = !can(one([
      for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
      if statement.Sid == "CreateServiceLinkedRoles"
      ]).Condition.StringEquals["iam:PermissionsBoundary"]) && contains(flatten([one([
        for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
        if statement.Sid == "CreateServiceLinkedRoles"
    ]).Condition.StringEquals["iam:AWSServiceName"]]), "batch.amazonaws.com")
    error_message = "Service-linked roles are a separate statement and cannot carry this boundary."
  }

  assert {
    condition = (
      one([
        for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
        if statement.Sid == "PassWorkloadRolesToEcsOnly"
      ]).Condition.StringEquals["iam:PassedToService"] == "ecs-tasks.amazonaws.com"
      && !can(one([
        for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
        if statement.Sid == "PassWorkloadRolesToEcsOnly"
      ]).Condition.StringEquals["iam:PermissionsBoundary"])
    )
    error_message = "PassRole must be limited to ecs-tasks. IAM does not evaluate iam:PermissionsBoundary on PassRole."
  }

  assert {
    condition = (
      length(replace(replace(replace(data.aws_iam_policy_document.deployment.json, " ", ""), "\n", ""), "\t", "")) <= 6144
      && length(replace(replace(replace(data.aws_iam_policy_document.deployment_workload.json, " ", ""), "\n", ""), "\t", "")) <= 6144
    )
    error_message = "Each deployment managed policy must stay within the 6144 non-whitespace character quota."
  }

  assert {
    condition = one([
      for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
      if statement.Sid == "DenyBoundaryRemoval"
    ]).Effect == "Deny"
    error_message = "Removing a permissions boundary must be denied."
  }

  assert {
    condition = (
      contains(flatten([one([
        for statement in jsondecode(data.aws_iam_policy_document.workload_boundary.json).Statement : statement
        if statement.Sid == "WorkloadServiceCeiling"
      ]).NotAction]), "iam:*")
      && !can(one([
        for statement in jsondecode(data.aws_iam_policy_document.workload_boundary.json).Statement : statement
        if statement.Sid == "WorkloadServiceCeiling"
      ]).Action)
      && one([
        for statement in jsondecode(data.aws_iam_policy_document.workload_boundary.json).Statement : statement
        if statement.Sid == "DenyStateSubstrate"
      ]).Effect == "Deny"
    )
    error_message = "The boundary ceiling must be NotAction, must not grant Action *, and must deny the state substrate."
  }
}
