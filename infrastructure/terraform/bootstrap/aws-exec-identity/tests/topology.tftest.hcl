# Each approved topology renders only the actions in the manifests it selects.
# The AWS provider renders policy JSON locally; override_data supplies the
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

run "ecs_with_redis" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for actions in values(output.deploy_identity_contract.actions_by_service) : [
        for action in actions : !strcontains(action, "*") && !strcontains(action, "?")
      ]
      ])) && alltrue([
      for size in values(output.deploy_identity_contract.policy_sizes.deployment_extra) : size <= 6144
    ])
    error_message = "Every allow action must be exact and every extra managed policy must fit the IAM limit."
  }

  variables {
    topology = {
      compute = "ecs"
      redis   = true
    }
  }

  assert {
    condition     = output.deploy_identity_contract.topology.compute == "ecs" && output.deploy_identity_contract.topology.redis == true && output.deploy_identity_contract.role_arn == "arn:aws:iam::123456789012:role/honua-prod-deploy"
    error_message = "The deploy contract must name the ECS+redis topology and the role to assume."
  }

  assert {
    condition = toset(flatten([
      for statement in concat(
        jsondecode(data.aws_iam_policy_document.deployment.json).Statement,
        jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement,
        flatten([for document in values(data.aws_iam_policy_document.deployment_extra) : jsondecode(document.json).Statement]),
      ) : statement.Effect == "Allow" ? try(tolist(statement.Action), [statement.Action]) : []
      ])) == toset(flatten([
      for id in ["iam-workload", "aws-ecs", "redis"] : concat(
        jsondecode(file("${path.module}/manifests/${id}.json")).region_actions,
        jsondecode(file("${path.module}/manifests/${id}.json")).global_actions,
        flatten([for statement in jsondecode(file("${path.module}/manifests/${id}.json")).iam_statements : statement.actions]),
      )
    ]))
    error_message = "ECS with redis must render exactly the iam-workload, aws-ecs, and redis manifest actions."
  }

  assert {
    condition = (
      contains(output.deploy_identity_contract.actions_by_service["elasticache"], "elasticache:CreateReplicationGroup")
      && contains(output.deploy_identity_contract.actions_by_service["elasticache"], "elasticache:DescribeReplicationGroups")
      && alltrue([for action in output.deploy_identity_contract.actions_by_service["elasticache"] : !strcontains(action, "*") && !strcontains(action, "?")])
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "eks")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "wafv2")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "batch")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "route53")
    )
    error_message = "ECS with redis includes ElastiCache and excludes EKS, WAF, Batch, and Route 53."
  }

  assert {
    condition = alltrue([
      for sid in ["DenyStateSubstrateAccess", "DenyLongLivedCredentials", "DenyPassingPrivilegedRoles", "DenyDeploymentIdentityMutation", "DenyBoundaryRemoval"] : contains([
        for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement.Sid
      ], sid)
    ])
    error_message = "Every separation deny must remain on the workload policy."
  }

  assert {
    condition = (
      length(replace(replace(replace(data.aws_iam_policy_document.deployment.json, " ", ""), "\n", ""), "\t", "")) <= 6144
      && length(replace(replace(replace(data.aws_iam_policy_document.deployment_workload.json, " ", ""), "\n", ""), "\t", "")) <= 6144
      && output.deploy_identity_contract.policy_sizes.inline_policies == 0
    )
    error_message = "Each managed policy must stay within 6144 non-whitespace characters, with no inline policy."
  }
}

run "ecs_without_redis" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for actions in values(output.deploy_identity_contract.actions_by_service) : [
        for action in actions : !strcontains(action, "*") && !strcontains(action, "?")
      ]
      ])) && alltrue([
      for size in values(output.deploy_identity_contract.policy_sizes.deployment_extra) : size <= 6144
    ])
    error_message = "Every allow action must be exact and every extra managed policy must fit the IAM limit."
  }

  variables {
    topology = {
      compute = "ecs"
      redis   = false
    }
  }

  assert {
    condition = (
      !contains(keys(output.deploy_identity_contract.actions_by_service), "elasticache")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "eks")
      && contains(output.deploy_identity_contract.actions_by_service["ecs"], "ecs:CreateCluster")
      && one([
        for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
        if statement.Sid == "CreateServiceLinkedRoles"
      ]).Condition.StringEquals["iam:AWSServiceName"] != null
      && !contains(flatten([one([
        for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
        if statement.Sid == "CreateServiceLinkedRoles"
      ]).Condition.StringEquals["iam:AWSServiceName"]]), "elasticache.amazonaws.com")
    )
    error_message = "ECS without redis must not grant ElastiCache actions or its service-linked role."
  }
}

run "eks" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for actions in values(output.deploy_identity_contract.actions_by_service) : [
        for action in actions : !strcontains(action, "*") && !strcontains(action, "?")
      ]
      ])) && alltrue([
      for size in values(output.deploy_identity_contract.policy_sizes.deployment_extra) : size <= 6144
    ])
    error_message = "Every allow action must be exact and every extra managed policy must fit the IAM limit."
  }

  variables {
    topology = {
      compute = "eks"
    }
  }

  assert {
    condition = toset(flatten([
      for statement in concat(
        jsondecode(data.aws_iam_policy_document.deployment.json).Statement,
        jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement,
        flatten([for document in values(data.aws_iam_policy_document.deployment_extra) : jsondecode(document.json).Statement]),
      ) : statement.Effect == "Allow" ? try(tolist(statement.Action), [statement.Action]) : []
      ])) == toset(flatten([
      for id in ["iam-workload", "aws-eks"] : concat(
        jsondecode(file("${path.module}/manifests/${id}.json")).region_actions,
        jsondecode(file("${path.module}/manifests/${id}.json")).global_actions,
        flatten([for statement in jsondecode(file("${path.module}/manifests/${id}.json")).iam_statements : statement.actions]),
      )
    ]))
    error_message = "EKS must render exactly the iam-workload and aws-eks manifest actions."
  }

  assert {
    condition = (
      contains(output.deploy_identity_contract.actions_by_service["eks"], "eks:CreateCluster")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "ecs")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "lambda")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "elasticache")
      && !contains(output.deploy_identity_contract.actions_by_service["elasticloadbalancing"], "elasticloadbalancing:CreateLoadBalancer")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "cloudwatch")
      && toset(flatten([one([
        for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
        if statement.Sid == "PassWorkloadRoles"
        ]).Condition.StringEquals["iam:PassedToService"]])) == toset([
        "ec2.amazonaws.com",
        "eks.amazonaws.com",
        "pods.eks.amazonaws.com",
      ])
    )
    error_message = "EKS PassRole is ec2, eks, and pods.eks, and the policy has no ECS, Lambda, or ElastiCache actions."
  }
}

run "lambda_without_redis" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for actions in values(output.deploy_identity_contract.actions_by_service) : [
        for action in actions : !strcontains(action, "*") && !strcontains(action, "?")
      ]
      ])) && alltrue([
      for size in values(output.deploy_identity_contract.policy_sizes.deployment_extra) : size <= 6144
    ])
    error_message = "Every allow action must be exact and every extra managed policy must fit the IAM limit."
  }

  variables {
    topology = {
      compute = "lambda"
      redis   = false
    }
  }

  assert {
    condition = toset(flatten([
      for statement in concat(
        jsondecode(data.aws_iam_policy_document.deployment.json).Statement,
        jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement,
        flatten([for document in values(data.aws_iam_policy_document.deployment_extra) : jsondecode(document.json).Statement]),
      ) : statement.Effect == "Allow" ? try(tolist(statement.Action), [statement.Action]) : []
      ])) == toset(flatten([
      for id in ["iam-workload", "aws-serverless"] : concat(
        jsondecode(file("${path.module}/manifests/${id}.json")).region_actions,
        jsondecode(file("${path.module}/manifests/${id}.json")).global_actions,
        flatten([for statement in jsondecode(file("${path.module}/manifests/${id}.json")).iam_statements : statement.actions]),
      )
    ]))
    error_message = "Lambda without redis must render exactly the iam-workload and aws-serverless manifest actions."
  }

  assert {
    condition = (
      contains(output.deploy_identity_contract.actions_by_service["lambda"], "lambda:CreateFunction")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "elasticache")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "eks")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "ecs")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "batch")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "s3")
      && length(replace(replace(replace(data.aws_iam_policy_document.deployment.json, " ", ""), "\n", ""), "\t", "")) <= 6144
      && length(replace(replace(replace(data.aws_iam_policy_document.deployment_workload.json, " ", ""), "\n", ""), "\t", "")) <= 6144
    )
    error_message = "Lambda without redis has no ElastiCache, EKS, ECS, or Batch actions, and both policies fit the managed-policy quota."
  }
}

run "lambda_with_domain" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for actions in values(output.deploy_identity_contract.actions_by_service) : [
        for action in actions : !strcontains(action, "*") && !strcontains(action, "?")
      ]
      ])) && alltrue([
      for size in values(output.deploy_identity_contract.policy_sizes.deployment_extra) : size <= 6144
    ])
    error_message = "Every allow action must be exact and every extra managed policy must fit the IAM limit."
  }

  variables {
    topology = {
      compute       = "lambda"
      custom_domain = true
    }
  }

  assert {
    condition = (
      contains(output.deploy_identity_contract.actions_by_service["acm"], "acm:RequestCertificate")
      && contains(output.deploy_identity_contract.actions_by_service["acm"], "acm:UpdateCertificateOptions")
      && contains(output.deploy_identity_contract.actions_by_service["acm"], "acm:ListTagsForCertificate")
      && contains(output.deploy_identity_contract.actions_by_service["route53"], "route53:GetHostedZone")
      && contains(output.deploy_identity_contract.actions_by_service["route53"], "route53:ListHostedZones")
      && contains(output.deploy_identity_contract.actions_by_service["route53"], "route53:ChangeResourceRecordSets")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "elasticache")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "wafv2")
      && contains(flatten([one([
        for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement
        if statement.Sid == "CreateServiceLinkedRoles"
      ]).Condition.StringEquals["iam:AWSServiceName"]]), "ops.apigateway.amazonaws.com")
      && alltrue([
        for sid in ["DenyStateSubstrateAccess", "DenyLongLivedCredentials", "DenyPassingPrivilegedRoles", "DenyDeploymentIdentityMutation", "DenyBoundaryRemoval"] : contains([
          for statement in jsondecode(data.aws_iam_policy_document.deployment_workload.json).Statement : statement.Sid
        ], sid)
      ])
      && length(replace(replace(replace(data.aws_iam_policy_document.deployment.json, " ", ""), "\n", ""), "\t", "")) <= 6144
    )
    error_message = "Lambda with a custom domain adds ACM and Route 53, keeps the denies, and does not add ElastiCache or WAF."
  }
}

run "lambda_release_cell" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for actions in values(output.deploy_identity_contract.actions_by_service) : [
        for action in actions : !strcontains(action, "*") && !strcontains(action, "?")
      ]
      ])) && alltrue([
      for size in values(output.deploy_identity_contract.policy_sizes.deployment_extra) : size <= 6144
    ])
    error_message = "Every allow action must be exact and every extra managed policy must fit the IAM limit."
  }

  variables {
    topology = {
      compute  = "lambda"
      redis    = true
      gp_batch = true
    }
  }

  assert {
    condition = (
      contains(keys(output.deploy_identity_contract.actions_by_service), "elasticache")
      && contains(keys(output.deploy_identity_contract.actions_by_service), "batch")
      && contains(output.deploy_identity_contract.actions_by_service["batch"], "batch:ListTagsForResource")
      && contains(output.deploy_identity_contract.actions_by_service["ecr"], "ecr:ListTagsForResource")
      && contains(output.deploy_identity_contract.actions_by_service["batch"], "batch:DescribeJobDefinitions")
      && alltrue([for action in output.deploy_identity_contract.actions_by_service["batch"] : !strcontains(action, "*") && !strcontains(action, "?")])
      && contains(output.deploy_identity_contract.actions_by_service["lambda"], "lambda:CreateFunction")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "eks")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "wafv2")
      && !contains(keys(output.deploy_identity_contract.actions_by_service), "route53")
      && output.deploy_identity_contract.batch_scope != null
      && length(replace(replace(replace(data.aws_iam_policy_document.deployment.json, " ", ""), "\n", ""), "\t", "")) <= 6144
      && length(replace(replace(replace(data.aws_iam_policy_document.deployment_workload.json, " ", ""), "\n", ""), "\t", "")) <= 6144
      && output.deploy_identity_contract.policy_sizes.inline_policies == 0
    )
    error_message = "The release-cell topology (Lambda, Redis, GP batch) must fit both managed policies and must not grant EKS, WAF, or Route 53."
  }
}

# The largest valid combinations exercise policy size and attachment limits.
run "ecs_all_features" {
  command = plan
  variables {
    topology = { compute = "ecs", redis = true, custom_domain = true, waf = true, gp_batch = true }
  }
  assert {
    condition = alltrue(concat(
      [output.deploy_identity_contract.policy_sizes.deployment <= 6144, output.deploy_identity_contract.policy_sizes.deployment_workload <= 6144],
      [for size in values(output.deploy_identity_contract.policy_sizes.deployment_extra) : size <= 6144],
    )) && length(output.deploy_identity_contract.policy_arns) <= 10 && contains(output.deploy_identity_contract.actions_by_service["wafv2"], "wafv2:AssociateWebACL") && !contains(output.deploy_identity_contract.actions_by_service["wafv2"], "wafv2:CreateWebACL")
    error_message = "All ECS managed policies must fit IAM document and role attachment limits."
  }
}

run "eks_all_features" {
  command = plan
  variables {
    topology = { compute = "eks", redis = true, custom_domain = true, waf = true, gp_batch = true }
  }
  assert {
    condition = alltrue(concat(
      [output.deploy_identity_contract.policy_sizes.deployment <= 6144, output.deploy_identity_contract.policy_sizes.deployment_workload <= 6144],
      [for size in values(output.deploy_identity_contract.policy_sizes.deployment_extra) : size <= 6144],
    )) && length(output.deploy_identity_contract.policy_arns) <= 10
    error_message = "All EKS managed policies must fit IAM document and role attachment limits."
  }
}

run "lambda_all_features" {
  command = plan
  variables {
    topology = { compute = "lambda", redis = true, custom_domain = true, waf = true, gp_batch = true }
  }
  assert {
    condition = alltrue(concat(
      [output.deploy_identity_contract.policy_sizes.deployment <= 6144, output.deploy_identity_contract.policy_sizes.deployment_workload <= 6144],
      [for size in values(output.deploy_identity_contract.policy_sizes.deployment_extra) : size <= 6144],
    )) && length(output.deploy_identity_contract.policy_arns) <= 10
    error_message = "All Lambda managed policies must fit IAM document and role attachment limits."
  }
}
