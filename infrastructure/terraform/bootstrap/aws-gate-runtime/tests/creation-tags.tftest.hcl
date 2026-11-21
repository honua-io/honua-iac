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
      toset(statement.Action) == toset(["ec2:CreateTags"]) &&
      jsonencode(statement.Condition) == jsonencode({
        StringNotLikeIfExists   = { "aws:RequestTag/aws:cloudformation:stack-name" = "honua-gate-*", "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" }
        StringNotEqualsIfExists = { "aws:ResourceTag/HonuaGate" = "true" }
        Null                    = { "ec2:CreateAction" = "true" }
      }), false)
    ])
    error_message = "EC2 post-create tagging needs a separate deny that spares the reserved CloudFormation stack-name request tag."
  }
  assert {
    condition = anytrue([for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : try(
      statement.Sid == "NamedCreationTags" && statement.Effect == "Deny" && statement.Resource == "*" &&
      contains(statement.Action, "acm:AddTagsToCertificate") &&
      jsonencode(statement.Condition) == jsonencode({
        StringNotLikeIfExists   = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" }
        StringNotEqualsIfExists = { "aws:RequestTag/HonuaGate" = "true", "aws:ResourceTag/HonuaGate" = "true" }
      }), false)
    ])
    error_message = "ACM post-create tagging must carry the stack's HonuaGate=true tag unless the certificate is already owned."
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
      for action in ["ec2:CreateTags", "acm:AddTagsToCertificate", "rds:AddTagsToResource", "cloudwatch:TagResource", "logs:TagResource", "lambda:TagResource"] : !anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "Workload roles keep the full ownership fence on tagging."
  }
  assert {
    condition = alltrue([for action in ["ec2:DeleteVpc", "acm:DeleteCertificate", "acm:RemoveTagsFromCertificate", "rds:DeleteDBParameterGroup", "rds:RestoreDBInstanceFromDBClusterSnapshot", "rds:RestoreDBInstanceToPointInTime", "rds:CreateDBInstanceReadReplica", "ec2:CreateVolume"] :
      !anytrue([for pattern in local.service_role_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "Deletion, restores and copies stay behind the ownership deny."
  }
  assert {
    # Gate stacks are created with CreateStack only; a change set could import a foreign resource into one.
    condition = !anytrue([for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement : try(
      statement.Effect == "Allow" && anytrue([for pattern in flatten([statement.Action]) : anytrue([
        for action in ["cloudformation:CreateChangeSet", "cloudformation:ExecuteChangeSet", "cloudformation:ImportResourcesToStack", "cloudformation:CreateStackRefactor"] : can(regex("(?i)^${replace(pattern, "*", ".*")}$", action))
      ])]), false
    )])
    error_message = "The lane must not create change sets or import: an import would let CloudFormation tag a resource the stack did not create."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.cloudformation_fences.role == aws_iam_role.cloudformation.name
    error_message = "The name fences must be attached to the CloudFormation service role."
  }
}

run "untaggable_types_are_managed_by_the_service_role_only" {
  command = plan
  assert {
    condition = alltrue([for action in ["cloudfront:CreateCachePolicy", "cloudfront:CreateOriginRequestPolicy", "cloudfront:CreateResponseHeadersPolicy",
      "cloudfront:CreateMonitoringSubscription", "cloudfront:DeleteMonitoringSubscription", "route53:CreateHealthCheck", "ecs:DeregisterTaskDefinition"] :
      anytrue([for pattern in local.service_role_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))]) &&
      !anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "These calls take no resource; only the service role may make them."
  }
  assert {
    condition = alltrue([for arn in [
      "arn:aws:cloudfront::000000000002:origin-access-control/E1SYNTHETIC",
      "arn:aws:cloudfront::000000000002:cache-policy/0000-synthetic",
      "arn:aws:cloudfront::000000000002:origin-request-policy/0000-synthetic",
      "arn:aws:cloudfront::000000000002:response-headers-policy/0000-synthetic",
      "arn:aws:cloudfront::000000000002:function/honua-gate-synthetic-router",
      "arn:aws:route53:::healthcheck/00000000-synthetic"
      ] : anytrue([for pattern in local.service_role_ownership_deny.NotResource : can(regex("^${replace(pattern, "*", ".*")}$", arn))])
      && !anytrue([for pattern in flatten([local.boundary_ownership_deny.NotResource]) : can(regex("^${replace(pattern, "*", ".*")}$", arn))])
    ])
    # Their Get calls are not metadata exemptions, so the ownership deny is the only statement that reaches them.
    error_message = "The service role must be able to read, update and delete its untaggable CloudFront resources and health checks; workload roles must not."
  }
  assert {
    condition = alltrue([for arn in [
      "arn:aws:cloudfront::000000000002:distribution/ESYNTHETIC",
      "arn:aws:cloudfront::000000000002:function/production-router",
      "arn:aws:cloudfront::000000000003:cache-policy/0000-synthetic",
      "arn:aws:route53:::hostedzone/ZSYNTHETIC"
      ] : !anytrue([for pattern in local.service_role_ownership_deny.NotResource : can(regex("^${replace(pattern, "*", ".*")}$", arn))])
    ])
    error_message = "Taggable distributions, functions outside the gate name, hosted zones and other accounts keep the ownership fence."
  }
  assert {
    condition = alltrue([for action in ["route53:ChangeResourceRecordSets", "route53:ChangeTagsForResource", "cloudfront:UpdateDistribution", "cloudfront:DeleteDistribution",
      "cloudfront:UpdateContinuousDeploymentPolicy", "cloudfront:DeleteContinuousDeploymentPolicy", "ecs:DeleteTaskDefinitions"] :
      !anytrue([for pattern in local.service_role_ownership_deny.NotAction : can(regex("^${replace(pattern, "*", ".*")}$", action))])
    ])
    error_message = "Record, hosted-zone tag and distribution changes keep the ownership fence; the subscription pattern must not reach them."
  }
}

run "ec2_and_acm_creation_and_post_creation_tagging_decisions" {
  command = plan
  assert {
    condition = alltrue([for scenario in [
      { name = "vpc_create", action = "ec2:CreateTags", denied = false, context = { "ec2:CreateAction" = "CreateVpc", "aws:RequestTag/HonuaGate" = "true" } },
      { name = "gateway_create", action = "ec2:CreateTags", denied = false, context = { "ec2:CreateAction" = "CreateInternetGateway", "aws:RequestTag/HonuaGate" = "true" } },
      { name = "create_missing_tag", action = "ec2:CreateTags", denied = true, context = { "ec2:CreateAction" = "CreateVpc" } },
      { name = "create_wrong_tag", action = "ec2:CreateTags", denied = true, context = { "ec2:CreateAction" = "CreateVpc", "aws:RequestTag/HonuaGate" = "false" } },
      { name = "foreign_post_create", action = "ec2:CreateTags", denied = true, context = { "aws:RequestTag/HonuaGate" = "true" } },
      { name = "owned_post_create", action = "ec2:CreateTags", denied = false, context = { "aws:ResourceTag/HonuaGate" = "true" } },
      { name = "foreign_stack_post_create", action = "ec2:CreateTags", denied = true, context = { "aws:RequestTag/aws:cloudformation:stack-name" = "foreign-stack", "aws:RequestTag/HonuaGate" = "true" } },
      # The ACM handler requests an untagged certificate, then tags it with the stack tags only (no reserved stack-name tag).
      { name = "certificate_post_create", action = "acm:AddTagsToCertificate", denied = false, context = { "aws:RequestTag/HonuaGate" = "true", "aws:RequestTag/honua:qualification" = "true" } },
      { name = "certificate_missing_tag", action = "acm:AddTagsToCertificate", denied = true, context = { "aws:RequestTag/honua:qualification" = "true" } },
      { name = "certificate_wrong_tag", action = "acm:AddTagsToCertificate", denied = true, context = { "aws:RequestTag/HonuaGate" = "false" } },
      # Accepted claim: only reachable through an import, which no gate principal can start.
      { name = "certificate_unowned_claim", action = "acm:AddTagsToCertificate", denied = false, context = { "aws:ResourceTag/HonuaGate" = "false", "aws:RequestTag/HonuaGate" = "true" } },
      { name = "certificate_stack_name_only", action = "acm:AddTagsToCertificate", denied = true, context = { "aws:RequestTag/aws:cloudformation:stack-name" = "honua-gate-m1-x" } },
      { name = "certificate_owned", action = "acm:AddTagsToCertificate", denied = false, context = { "aws:ResourceTag/HonuaGate" = "true" } }
      ] : scenario.denied == anytrue([
        for statement in jsondecode(aws_iam_policy.cloudformation_fences.policy).Statement : try(
          statement.Effect == "Deny" && contains(flatten([statement.Action]), scenario.action) &&
          alltrue([for operator, entries in try(statement.Condition, {}) : alltrue([
            for key, value in entries :
            operator == "Null" ? tostring(!contains(keys(scenario.context), key)) == value :
            operator == "StringNotEqualsIfExists" ? try(scenario.context[key] != value, true) :
            operator == "StringNotLikeIfExists" ? !can(regex("^${replace(value, "*", ".*")}$", scenario.context[key])) : false
        ])]), false)
      ])
    ])
    error_message = "EC2 create-time tags require HonuaGate=true; post-create EC2 tagging cannot claim an unowned resource with a customer request tag; ACM tagging needs the HonuaGate=true stack tag."
  }
}

run "network_cleanup_is_disabled_by_default" {
  command = plan
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      !anytrue([for statement in jsondecode(policy).Statement : try(statement.Sid == "TemporaryNetworkCleanup", false)])
    ])
    error_message = "Empty cleanup inputs must grant no network deletion permission."
  }
}

run "network_cleanup_uses_only_exact_ids_and_three_actions" {
  command = plan
  variables {
    temporary_cleanup_vpc_ids     = ["vpc-00000000000000001", "vpc-00000000000000002"]
    temporary_cleanup_gateway_ids = ["igw-00000000000000001", "igw-00000000000000002"]
  }
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.lane.policy, aws_iam_policy.lane_boundary.policy] :
      length([for statement in jsondecode(policy).Statement : statement if try(
        statement.Sid == "TemporaryNetworkCleanup" && statement.Effect == "Allow" &&
        toset(statement.Action) == toset(["ec2:DeleteVpc", "ec2:DeleteInternetGateway", "ec2:DetachInternetGateway"]) &&
        toset(statement.Resource) == toset([
          "arn:aws:ec2:us-east-1:000000000002:vpc/vpc-00000000000000001",
          "arn:aws:ec2:us-east-1:000000000002:vpc/vpc-00000000000000002",
          "arn:aws:ec2:us-east-1:000000000002:internet-gateway/igw-00000000000000001",
          "arn:aws:ec2:us-east-1:000000000002:internet-gateway/igw-00000000000000002"
      ]), false)]) == 1
    ])
    error_message = "Both lane identity and boundary must allow exactly the reviewed network IDs and three cleanup actions."
  }
  assert {
    condition = alltrue([for policy in [aws_iam_role_policy.cloudformation.policy, aws_iam_policy.cloudformation_fences.policy, aws_iam_policy.workload_boundary.policy] :
      !strcontains(policy, "TemporaryNetworkCleanup")
    ])
    error_message = "Temporary cleanup must not weaken CloudFormation or workload ownership fences."
  }
}

run "reject_wildcard_cleanup_ids" {
  command = plan
  variables { temporary_cleanup_vpc_ids = ["vpc-*"] }
  expect_failures = [var.temporary_cleanup_vpc_ids]
}

run "reject_more_than_two_cleanup_gateways" {
  command = plan
  variables { temporary_cleanup_gateway_ids = ["igw-00000001", "igw-00000002", "igw-00000003"] }
  expect_failures = [var.temporary_cleanup_gateway_ids]
}

run "acm_may_use_its_managed_key_for_the_service_role_only" {
  command = plan
  assert {
    condition = {
      for key, value in local.service_role_ownership_deny.Condition : key => value if key != "StringNotLike"
      } == local.ownership_condition && local.service_role_ownership_deny.Condition.StringNotLike == { "kms:ViaService" = "acm.*" } && alltrue([
        for scenario in [
          { name = "acm_grant_on_managed_key", denied = false, context = { "kms:ViaService" = "acm.us-east-1.amazonaws.com" } },
          { name = "direct_grant_on_managed_key", denied = true, context = {} },
          { name = "other_service_on_managed_key", denied = true, context = { "kms:ViaService" = "ec2.us-east-1.amazonaws.com" } },
          { name = "owned_key", denied = false, context = { "aws:ResourceTag/HonuaGate" = "true" } }
          ] : scenario.denied == alltrue([
            for operator, entries in local.service_role_ownership_deny.Condition : alltrue([
              for key, value in entries :
              operator == "StringNotLike" ? !can(regex("^${replace(value, "*", ".*")}$", scenario.context[key])) :
              operator == "StringNotEqualsIfExists" ? try(scenario.context[key] != value, true) :
              operator == "StringNotLikeIfExists" ? !can(regex("^${replace(value, "*", ".*")}$", scenario.context[key])) : false
            ])
        ])
    ]) && local.boundary_ownership_deny.Condition.StringNotLike == { "kms:ViaService" = "secretsmanager.*" }
    error_message = "Only KMS calls ACM makes for the service role may skip the ownership tag on a key; workload roles keep the Secrets Manager exemption alone."
  }
}
