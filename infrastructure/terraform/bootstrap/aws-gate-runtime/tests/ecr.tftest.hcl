# Synthetic fixtures only; deployment identifiers come from private SSM configuration.
mock_provider "aws" {
  override_during = plan
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:us-east-1:000000000002:secret:honua-gate/idp/client-secret-abcdef" } }
  mock_resource "aws_cognito_user_pool" { defaults = { id = "us-east-1_Synthetic", arn = "arn:aws:cognito-idp:us-east-1:000000000002:userpool/us-east-1_Synthetic" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::000000000002:role/mock" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::000000000002:policy/mock" } }
  mock_resource "aws_lambda_function" { defaults = { arn = "arn:aws:lambda:us-east-1:000000000002:function:honua-gate-reaper" } }
  mock_resource "aws_cloudwatch_event_rule" { defaults = { arn = "arn:aws:events:us-east-1:000000000002:rule/mock" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-east-1:000000000002:log-group:/aws/lambda/honua-gate-reaper" } }
}
mock_provider "archive" {}
variables {
  member_account_id   = format("%012d", 2)
  lane_principal_arns = [format("arn:aws:iam::%s:role/GateOperator", format("%012d", 1))]
}

run "server_repository_is_immutable_scanned_and_bounded" {
  command = plan
  assert {
    condition     = aws_ecr_repository.server.name == "honua-gate/server" && aws_ecr_repository.server.image_tag_mutability == "IMMUTABLE"
    error_message = "One gate server repository whose tags cannot be repointed, so a digest keeps meaning one image."
  }
  assert {
    condition     = one(aws_ecr_repository.server.image_scanning_configuration).scan_on_push && one(aws_ecr_repository.server.encryption_configuration).encryption_type == "AES256"
    error_message = "Images are scanned on push and encrypted with ECR-managed keys, which need no KMS grant through the gate fences."
  }
  assert {
    condition = jsondecode(aws_ecr_lifecycle_policy.server.policy).rules == [{
      rulePriority = 1, description = "Keep the newest ${local.kept_server_images} images", action = { type = "expire" }
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = local.kept_server_images }
    }]
    error_message = "The repository keeps the newest images and expires older ones."
  }
}

run "lane_pushes_to_the_gate_repository_only" {
  command = plan
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement :
      try(statement.Sid == "GateImagePush" && statement.Effect == "Allow" && toset(statement.Action) == toset(local.image_push_actions) && statement.Resource == local.server_repository_arn, false)
      ]) && anytrue([
      for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement :
      try(statement.Sid == "RegistryLogin" && statement.Action == "ecr:GetAuthorizationToken" && statement.Resource == "*", false)
    ]) && aws_iam_policy.lane_boundary.policy == aws_iam_role_policy.lane.policy
    error_message = "The lane may log in, push and read manifests in the gate server repository, and its boundary allows the same."
  }
  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.lane.policy).Statement : statement.Effect != "Allow" || alltrue([
        for pattern in flatten([try(statement.Action, "*")]) : alltrue([
          for action in ["ecr:BatchDeleteImage", "ecr:DeleteRepository", "ecr:DeleteRepositoryPolicy", "ecr:SetRepositoryPolicy", "ecr:PutLifecyclePolicy", "ecr:DeleteLifecyclePolicy", "ecr:PutImageTagMutability", "ecr:TagResource"] : !can(regex("(?i)^${replace(replace(replace(pattern, "/[.+()\\[\\]{}|^$\\\\]/", "\\$0"), "*", ".*"), "?", ".")}$", action))
        ])
      ])
    ])
    error_message = "The lane gets no other ECR write, including by wildcard: no image or repository deletion, policy, lifecycle or tag change."
  }
}

run "stacks_can_pull_but_never_write_images" {
  command = plan
  assert {
    condition = alltrue([
      for policy in [aws_iam_policy.workload_boundary.policy, aws_iam_role_policy.cloudformation.policy] : alltrue([
        for statement in jsondecode(policy).Statement : statement.Effect != "Allow" || alltrue([
          for pattern in flatten([try(statement.Action, "*")]) : alltrue([for action in ["ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchDeleteImage", "ecr:DeleteRepository", "ecr:DeleteRepositoryPolicy", "ecr:SetRepositoryPolicy", "ecr:PutLifecyclePolicy", "ecr:DeleteLifecyclePolicy", "ecr:PutImageTagMutability", "ecr:TagResource"] : !can(regex("(?i)^${replace(replace(replace(pattern, "/[.+()\\[\\]{}|^$\\\\]/", "\\$0"), "*", ".*"), "?", ".")}$", action))])
        ])
      ])
    ])
    error_message = "Launch Stack roles and their boundary must not push, delete or re-policy images, including by wildcard."
  }
  assert {
    # Exact spellings: a broader wildcard such as ecr:Get* would grant repository policy reads.
    condition     = toset([for pattern in local.workload_services : pattern if startswith(lower(pattern), "ecr:")]) == toset(["ecr:GetAuth*", "ecr:BatchGetImage", "ecr:GetDownload*", "ecr:BatchCheck*"])
    error_message = "The workload boundary allows exactly the four pull actions a task execution role needs."
  }
}

run "shared_account_exempts_only_the_gate_repository" {
  command = plan
  variables {
    shared_account          = true
    protected_state_buckets = [for index in range(2) : format("synthetic-state-%047d", index)]
    protected_ssm_paths     = [for index in range(18) : format("/synthetic/gate/runtime/protected-parameter-%02d", index)]
    budget_alert_email      = "gate@example.invalid"
  }
  assert {
    condition     = toset(local.boundary_ownership_deny.NotResource) == toset([aws_secretsmanager_secret.idp_client.arn, local.boundary_repository_arn, "arn:aws:ecr:*:*:repository/aws-guardduty-agent-fargate"]) && contains(local.boundary_ownership_deny.NotAction, "ecr:GetAuth*") && local.boundary_repository_arn == replace(local.server_repository_arn, ":us-east-1:", ":*:")
    error_message = "Workloads may log in to the registry and pull from the Terraform-owned gate repository and the exact AWS GuardDuty agent repository, neither of which carries a stack tag."
  }
  assert {
    condition = alltrue([
      for action in ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"] :
      !anytrue([for pattern in local.boundary_ownership_deny.NotAction : can(regex("(?i)^${replace(replace(replace(pattern, "/[.+()\\[\\]{}|^$\\\\]/", "\\$0"), "*", ".*"), "?", ".")}$", action))])
    ])
    error_message = "Image reads from any other untagged or foreign repository stay denied by the ownership fence."
  }
  assert {
    condition = alltrue([
      for request in [["ecr:GetAuthorizationToken", "*"], ["ecr:BatchGetImage", local.server_repository_arn], ["ecr:GetDownloadUrlForLayer", local.server_repository_arn], ["ecr:BatchCheckLayerAvailability", local.server_repository_arn]] : alltrue([
        for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : statement.Effect != "Deny" || try(statement.Sid, "") == "DenyOtherRegions" || !(
          try(anytrue([for pattern in flatten([statement.Action]) : can(regex("(?i)^${replace(replace(replace(pattern, "/[.+()\\[\\]{}|^$\\\\]/", "\\$0"), "*", ".*"), "?", ".")}$", request[0]))]), !anytrue([for pattern in flatten([statement.NotAction]) : can(regex("(?i)^${replace(replace(replace(pattern, "/[.+()\\[\\]{}|^$\\\\]/", "\\$0"), "*", ".*"), "?", ".")}$", request[0]))])) &&
          try(anytrue([for pattern in flatten([statement.Resource]) : can(regex("^${replace(replace(replace(pattern, "/[.+()\\[\\]{}|^$\\\\]/", "\\$0"), "*", ".*"), "?", ".")}$", request[1]))]), !anytrue([for pattern in flatten([statement.NotResource]) : can(regex("^${replace(replace(replace(pattern, "/[.+()\\[\\]{}|^$\\\\]/", "\\$0"), "*", ".*"), "?", ".")}$", request[1]))]))
        )
      ])
    ])
    error_message = "No workload-boundary deny may block registry login or a pull from the gate repository in us-east-1, whatever its conditions."
  }
  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(statement.Sid, "") != "DenyOtherRegions" || try(
        flatten([statement.Condition.StringNotEquals["aws:RequestedRegion"]]) == ["us-east-1"] && length(keys(statement.Condition)) == 1 && length(keys(statement.Condition.StringNotEquals)) == 1,
        false
      )
    ])
    error_message = "The region deny skipped above must keep sparing exactly us-east-1 and nothing else."
  }
  assert {
    # The exempt repository ARN has a region wildcard; this deny is what keeps pulls in us-east-1.
    condition = anytrue([
      for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement : try(statement.Sid, "") == "DenyOtherRegions" && alltrue([
        for action in ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability", "ecr:GetAuthorizationToken"] :
        try(anytrue([for pattern in flatten([statement.Action]) : can(regex("(?i)^${replace(replace(replace(pattern, "/[.+()\\[\\]{}|^$\\\\]/", "\\$0"), "*", ".*"), "?", ".")}$", action))]), !anytrue([for pattern in flatten([statement.NotAction]) : can(regex("(?i)^${replace(replace(replace(pattern, "/[.+()\\[\\]{}|^$\\\\]/", "\\$0"), "*", ".*"), "?", ".")}$", action))]))
      ])
    ])
    error_message = "The region deny must cover every ECR pull action, or the region-wildcard exemption would reach other regions."
  }
  assert {
    # Beyond the IdP secret it spares only untaggable CloudFront types, health checks (creation-tags.tftest.hcl) and delivery resources (waf-logs.tftest.hcl).
    condition     = toset(local.service_role_ownership_deny.NotResource) == toset(concat([aws_secretsmanager_secret.idp_client.arn, local.delivery_arns], local.untaggable_arns))
    error_message = "The CloudFormation role needs no image access and keeps the unchanged ownership fence."
  }
}

run "cloudformation_passes_the_stack_delivery_role_to_eventbridge" {
  command = plan
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.cloudformation.policy).Statement :
      try(statement.Action == "iam:PassRole" && statement.Effect == "Allow" && statement.Resource == local.workload_roles && contains(statement.Condition.StringEquals["iam:PassedToService"], "events.amazonaws.com"), false)
    ])
    error_message = "A stack's EventBridge rule delivers through a gate role that CloudFormation passes to events."
  }
  assert {
    # Fails closed: a PassRole allow without a service condition could pass to EventBridge.
    condition = alltrue([
      for statement in jsondecode(aws_iam_policy.workload_boundary.policy).Statement :
      statement.Effect != "Allow" || !anytrue([for pattern in flatten([try(statement.Action, "*")]) : can(regex("(?i)^${replace(replace(replace(pattern, "/[.+()\\[\\]{}|^$\\\\]/", "\\$0"), "*", ".*"), "?", ".")}$", "iam:PassRole"))]) || (
        can(statement.Condition.StringEquals["iam:PassedToService"]) && !contains(flatten([try(statement.Condition.StringEquals["iam:PassedToService"], [])]), "events.amazonaws.com")
      )
    ])
    error_message = "Workload roles never pass roles to EventBridge; only the service role does."
  }
}
