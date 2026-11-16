# Synthetic fixtures only. EC2 and RDS handlers tag a resource after creating it, and CloudFront policies and
# origin access controls cannot carry tags at all. Only the CloudFormation service role gets either exception.
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

run "only_cloudformation_creation_tags_spare_an_untagged_resource" {
  command = plan
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : try(
      statement.Sid == "CreationTags" && statement.Effect == "Deny" && statement.Resource == "*" &&
      toset(statement.Action) == toset(["ec2:CreateTags", "rds:AddTagsToResource"]) &&
      jsonencode(statement.Condition) == jsonencode({
        StringNotLikeIfExists   = { "aws:RequestTag/aws:cloudformation:stack-name" = "honua-gate-*", "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" }
        StringNotEqualsIfExists = { "aws:ResourceTag/HonuaGate" = "true" }
      }), false)
    ])
    error_message = "The two tag-after-create APIs need their own deny that spares only the reserved CloudFormation stack-name request tag."
  }
  assert {
    # A create or restore request carries the same request tag; only the tagging APIs may trust it.
    condition = alltrue([for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.cloudformation_fences.policy, aws_iam_policy.workload_boundary.policy] : alltrue([
      for statement in jsondecode(policy).Statement : !strcontains(jsonencode(try(statement.Condition, {})), "aws:RequestTag/aws:cloudformation:stack-name") ||
      contains(["CreationTags", "PoolTags"], try(statement.Sid, ""))
    ])])
    error_message = "Only the CreationTags and PoolTags denies may read the CloudFormation stack-name request tag."
  }
  assert {
    condition = !anytrue([for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(statement.Sid == "CreationTags", false)]) && alltrue([
      for action in ["ec2:CreateTags", "rds:AddTagsToResource"] : !anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "Workload roles keep the full ownership fence on tagging."
  }
  assert {
    condition = alltrue([for action in ["ec2:DeleteVpc", "rds:DeleteDBParameterGroup", "rds:RestoreDBInstanceFromDBSnapshot", "rds:CreateDBInstanceReadReplica", "ec2:CreateVolume"] :
      !anytrue([for pattern in local.service_role_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "Deletion, restores and copies stay behind the ownership deny."
  }
  assert {
    # Gate stacks are created with CreateStack only; a change set could import a foreign resource into one.
    condition = !anytrue([for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement : try(
      statement.Effect == "Allow" && anytrue([for pattern in flatten([statement.Action]) : anytrue([
        for action in ["cloudformation:CreateChangeSet", "cloudformation:ExecuteChangeSet"] : can(regex("(?i)^${replace(pattern, "*", ".*")}$", action))
      ])]), false
    )])
    error_message = "The lane must not create change sets: an import would let CloudFormation tag a resource the stack did not create."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.cloudformation_fences.role == aws_iam_role.cloudformation.name
    error_message = "The name fences must be attached to the CloudFormation service role."
  }
}

run "untaggable_cloudfront_types_are_managed_by_the_service_role_only" {
  command = plan
  assert {
    condition = alltrue([for action in ["cloudfront:CreateCachePolicy", "cloudfront:CreateOriginRequestPolicy", "cloudfront:CreateResponseHeadersPolicy"] :
      contains(local.service_role_ownership_deny.NotAction, action) && !contains(local.boundary_ownership_deny.NotAction, action)
    ])
    error_message = "CloudFront policy creation takes no resource; only the service role may allocate it."
  }
  assert {
    condition = alltrue([for arn in [
      "arn:aws:cloudfront::000000000002:origin-access-control/E1SYNTHETIC",
      "arn:aws:cloudfront::000000000002:cache-policy/0000-synthetic",
      "arn:aws:cloudfront::000000000002:origin-request-policy/0000-synthetic",
      "arn:aws:cloudfront::000000000002:response-headers-policy/0000-synthetic",
      "arn:aws:cloudfront::000000000002:function/honua-gate-synthetic-router"
      ] : anytrue([for pattern in local.service_role_ownership_deny.NotResource : can(regex("^${replace(pattern, "*", ".*")}$", arn))])
      && !anytrue([for pattern in flatten([local.boundary_ownership_deny.NotResource]) : can(regex("^${replace(pattern, "*", ".*")}$", arn))])
    ])
    # Their Get calls are not metadata exemptions, so the ownership deny is the only statement that reaches them.
    error_message = "The service role must be able to read, update and delete its untaggable CloudFront resources; workload roles must not."
  }
  assert {
    condition = alltrue([for arn in [
      "arn:aws:cloudfront::000000000002:distribution/ESYNTHETIC",
      "arn:aws:cloudfront::000000000002:function/production-router",
      "arn:aws:cloudfront::000000000003:cache-policy/0000-synthetic"
      ] : !anytrue([for pattern in local.service_role_ownership_deny.NotResource : can(regex("^${replace(pattern, "*", ".*")}$", arn))])
    ])
    error_message = "Taggable distributions, functions outside the gate name and other accounts keep the ownership fence."
  }
}
