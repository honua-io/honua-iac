# Synthetic fixtures only; no live AWS calls.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/client-secret-abcdef" } }
  mock_resource "aws_cognito_user_pool" { defaults = { id = "us-east-1_Synthetic", arn = "arn:aws:cognito-idp:us-east-1:000000000002:userpool/us-east-1_Synthetic" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::000000000002:role/mock" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
}
mock_provider "archive" {}
override_resource {
  target          = aws_secretsmanager_secret.idp_viewer
  override_during = plan
  values          = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/viewer-abcdef" }
}
variables {
  member_account_id       = "000000000002"
  lane_principal_arns     = ["arn:aws:iam::000000000001:role/GateOperator"]
  shared_account          = true
  protected_state_buckets = ["synthetic-state"]
  protected_ssm_paths     = ["/synthetic/gate"]
  budget_alert_email      = "gate@example.invalid"
}

run "viewer_signs_in_without_a_role_and_its_secret_stays_fenced" {
  command = plan
  assert {
    condition     = aws_cognito_user.viewer.username == "honua-gate-viewer" && aws_cognito_user_in_group.admin.username != aws_cognito_user.viewer.username && aws_cognito_user.viewer.message_action == "SUPPRESS"
    error_message = "The viewer is a pool user outside the admin group."
  }
  assert {
    condition = !contains(keys(coalesce(aws_secretsmanager_secret.idp_viewer.tags, {})), "HonuaGate") && alltrue([
      for allowed in concat(local.boundary_ownership_deny.NotResource, local.service_role_ownership_deny.NotResource, local.idp_client_readers) :
      allowed != aws_secretsmanager_secret.idp_viewer.arn && !strcontains(allowed, "idp/viewer")
    ])
    error_message = "The viewer secret must carry no gate ownership tag and stay outside every ownership-fence exemption, so no gate principal can read it."
  }
  assert {
    condition = anytrue([for control in local.shared_controls : try(
      control.Sid == "DenyNonGateContentReads" && contains(control.Action, "secretsmanager:GetSecretValue") && !contains(control.NotResource, aws_secretsmanager_secret.idp_viewer.arn), false
    )])
    error_message = "The service role's content-read fence must cover the viewer secret."
  }
  assert {
    condition     = jsondecode(aws_secretsmanager_secret_policy.idp_viewer.policy).Statement[0].Effect == "Deny" && toset(jsondecode(aws_secretsmanager_secret_policy.idp_viewer.policy).Statement[0].Condition.ArnLike["aws:PrincipalArn"]) == toset(["arn:aws:iam::000000000002:role/honua-gate-*", "arn:aws:iam::000000000002:role/HonuaGate*"])
    error_message = "The viewer secret's own policy denies every gate role, independent of tags."
  }
}

run "lane_reads_one_stack_resource_and_lists_clusters" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      anytrue([for statement in jsondecode(policy).Statement : try(
        contains(statement.Action, "cloudformation:DescribeStackResource") && statement.Resource == "arn:aws:cloudformation:us-east-1:000000000002:stack/honua-gate-*/*", false
        )]) && anytrue([for statement in jsondecode(policy).Statement : try(
        contains(statement.Action, "ecs:ListClusters") && statement.Resource == "*" && length([for action in statement.Action : action if startswith(action, "ecs:")]) == 1, false
      )])
    ])
    error_message = "The lane may describe a resource of a gate stack and list cluster ARNs, and no other ECS action account-wide."
  }
}

run "batch_queue_metadata_is_not_a_content_read" {
  command = plan
  assert {
    condition = !anytrue([for action in local.shared_content_read_actions : can(regex("(?i)^${replace(action, "*", ".*")}$", "batch:DescribeJobQueues"))]) && alltrue([
      for read in ["batch:DescribeJobs", "batch:DescribeJobDefinitions", "batch:DescribeServiceJob"] :
      anytrue([for action in local.shared_content_read_actions : can(regex("(?i)^${replace(action, "*", ".*")}$", read))])
    ])
    error_message = "Job and job-definition reads stay content reads; the job queue handler's DescribeJobQueues must not be fenced as one."
  }
}

run "lane_reads_only_the_idp_admin_secret" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      length([for statement in jsondecode(policy).Statement : statement if try(statement.Effect == "Allow" && anytrue([
        for action in flatten([statement.Action]) : startswith(action, "secretsmanager:")
        ]), false)]) == 1 && anytrue([for statement in jsondecode(policy).Statement : try(
        statement.Sid == "ReadIdpAdminSecret" && statement.Action == "secretsmanager:GetSecretValue" && statement.Resource == "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/admin-??????", false
      )])
    ])
    error_message = "The lane may read the IdP admin secret's value and no other Secrets Manager action or secret."
  }
}
