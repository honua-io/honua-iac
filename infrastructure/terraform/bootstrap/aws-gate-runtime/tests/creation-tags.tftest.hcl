# Synthetic fixtures only. A first full Launch Stack create in the gate (16 Nov 2026) showed two gaps in the
# ownership fence: EC2 and RDS handlers tag a resource after creating it, and CloudFront policies and origin
# access controls cannot carry tags at all. Only the CloudFormation service role gets either exception.
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
    condition = (
      local.service_role_ownership_deny.Condition.StringNotLikeIfExists["aws:RequestTag/aws:cloudformation:stack-name"] == "honua-gate-*" &&
      !can(local.boundary_ownership_deny.Condition.StringNotLikeIfExists["aws:RequestTag/aws:cloudformation:stack-name"]) &&
      alltrue([for deny in [local.boundary_ownership_deny, local.service_role_ownership_deny] : alltrue([
        for key in keys(deny.Condition.StringNotEqualsIfExists) : !startswith(key, "aws:RequestTag/")
      ])])
    )
    error_message = "Only the reserved CloudFormation stack-name request tag may spare a tagging call; any principal can send HonuaGate=true."
  }
  assert {
    condition = alltrue([for action in ["ec2:CreateTags", "rds:AddTagsToResource", "ec2:DeleteVpc", "rds:DeleteDBParameterGroup"] :
      !anytrue([for pattern in local.service_role_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "Tagging and deletion stay behind the ownership deny; only the request-tag condition spares the creation step."
  }
  assert {
    # Gate stacks are created with CreateStack only; a change set could import a foreign resource into one.
    condition = !anytrue([for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement : try(
      statement.Effect == "Allow" && anytrue([for action in flatten([statement.Action]) : startswith(action, "cloudformation:") && (strcontains(action, "ChangeSet") || strcontains(action, "Import"))]), false
    )])
    error_message = "The lane must not create change sets: an import would let CloudFormation tag a resource the stack did not create."
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
