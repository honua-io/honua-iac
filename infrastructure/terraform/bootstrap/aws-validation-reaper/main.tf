# OIDC role for sweep-orphaned-validation-infra.sh: the scheduled
# terraform-validation-infra-reaper.yml job and terraform-manual-validation.yml's
# always-step that reaps its own cell. Until this root is applied and
# HONUA_AWS_VALIDATION_REAPER_ROLE_ARN is set, the scheduled reaper concludes
# `skipped` every night and strands accumulate (VPC quota exhaustion, 2026-10-26).
#
# Least privilege for exactly the sweep's calls: reads it needs to prove a
# resource is orphaned, and the delete verbs of its teardown. The script's
# refusal rules decide WHAT is deleted; the denies below are the independent
# backstop for what may never be touched, mirroring the release-cell guardrail
# (bootstrap/aws-release-cells/policies/guardrails.json.tftpl).

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  read_actions = [
    "tag:GetResources",
    "cloudtrail:LookupEvents",
    "ec2:Describe*",
    "ecs:Describe*",
    "ecs:List*",
    "elasticloadbalancing:Describe*",
    "rds:Describe*",
    "elasticache:Describe*",
    "secretsmanager:DescribeSecret",
    "secretsmanager:ListSecrets",
    "logs:DescribeLogGroups",
    "lambda:GetFunction",
    "lambda:ListFunctions",
    "kms:DescribeKey",
  ]

  delete_actions = [
    "ec2:DeleteNatGateway",
    "ec2:ReleaseAddress",
    "ec2:DeleteVpcEndpoints",
    "ec2:DetachInternetGateway",
    "ec2:DeleteInternetGateway",
    "ec2:RevokeSecurityGroupIngress",
    "ec2:RevokeSecurityGroupEgress",
    "ec2:DeleteSecurityGroup",
    "ec2:DeleteNetworkInterface",
    "ec2:DeleteSubnet",
    "ec2:DisassociateRouteTable",
    "ec2:DeleteRouteTable",
    "ec2:DeleteVpc",
    "ecs:UpdateService",
    "ecs:DeleteService",
    "ecs:DeleteCluster",
    "ecs:DeregisterTaskDefinition",
    "elasticloadbalancing:DeleteListener",
    "elasticloadbalancing:DeleteLoadBalancer",
    "elasticloadbalancing:DeleteTargetGroup",
    "rds:DeleteDBInstance",
    "rds:DeleteDBProxy",
    "rds:DeleteDBSubnetGroup",
    "rds:DeleteDBParameterGroup",
    "elasticache:DeleteReplicationGroup",
    "elasticache:DeleteCacheCluster",
    "elasticache:DeleteCacheSubnetGroup",
    "elasticache:DeleteCacheParameterGroup",
    "secretsmanager:DeleteSecret",
    "logs:DeleteLogGroup",
    "lambda:DeleteFunction",
    "kms:ScheduleKeyDeletion",
  ]

  protected_names = [
    "arn:aws:lambda:*:${local.account_id}:function:honua-cert-*",
    "arn:aws:lambda:*:${local.account_id}:function:honua-demo-*",
    "arn:aws:rds:*:${local.account_id}:db:honua-cert-*",
    "arn:aws:rds:*:${local.account_id}:db:honua-demo-*",
    "arn:aws:rds:*:${local.account_id}:subgrp:honua-cert-*",
    "arn:aws:rds:*:${local.account_id}:subgrp:honua-demo-*",
    "arn:aws:ecs:*:${local.account_id}:cluster/honua-cert-*",
    "arn:aws:ecs:*:${local.account_id}:cluster/honua-demo-*",
    "arn:aws:secretsmanager:*:${local.account_id}:secret:honua-cert-*",
    "arn:aws:secretsmanager:*:${local.account_id}:secret:honua-demo-*",
    "arn:aws:logs:*:${local.account_id}:log-group:*honua-cert-*",
    "arn:aws:logs:*:${local.account_id}:log-group:*honua-demo-*",
    "arn:aws:elasticache:*:${local.account_id}:replicationgroup:honua-cert-*",
    "arn:aws:elasticache:*:${local.account_id}:replicationgroup:honua-demo-*",
  ]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ProveOrphaned", Effect = "Allow", Action = local.read_actions, Resource = "*" },
      { Sid = "TearDownCells", Effect = "Allow", Action = local.delete_actions, Resource = "*" },
      {
        Sid       = "SweepRegionsOnly"
        Effect    = "Deny"
        NotAction = ["iam:*", "sts:*"]
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:RequestedRegion" = var.sweep_regions } }
      },
      {
        Sid      = "NoRoleChainingOrIam"
        Effect   = "Deny"
        Action   = ["sts:AssumeRole", "sts:AssumeRoleWithWebIdentity", "sts:AssumeRoleWithSAML", "sts:GetFederationToken", "iam:*"]
        Resource = "*"
      },
      {
        Sid      = "NeverRetag"
        Effect   = "Deny"
        Action   = ["ec2:CreateTags", "ec2:DeleteTags", "tag:TagResources", "tag:UntagResources", "ecs:TagResource", "ecs:UntagResource", "rds:AddTagsToResource", "rds:RemoveTagsFromResource", "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags", "lambda:TagResource", "lambda:UntagResource", "logs:TagResource", "logs:UntagResource", "secretsmanager:TagResource", "secretsmanager:UntagResource", "elasticache:AddTagsToResource", "elasticache:RemoveTagsFromResource", "kms:TagResource", "kms:UntagResource"]
        Resource = "*"
      },
      {
        Sid       = "ProtectStandingEnvironment"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { StringEquals = { "aws:ResourceTag/Environment" = ["cert", "standing", "demo"] } }
      },
      {
        Sid       = "ProtectStandingLifecycle"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { StringEquals = { "aws:ResourceTag/Lifecycle" = ["standing", "demo"] } }
      },
      {
        Sid       = "ProtectStandingOwner"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { StringEquals = { "aws:ResourceTag/Owner" = ["release-standing"] } }
      },
      {
        Sid       = "ProtectPublicDemo"
        Effect    = "Deny"
        Action    = "*"
        Resource  = "*"
        Condition = { StringEquals = { "aws:ResourceTag/Purpose" = ["public-demo"] } }
      },
      {
        Sid       = "ProtectEc2Environment"
        Effect    = "Deny"
        Action    = "ec2:*"
        Resource  = "*"
        Condition = { StringEquals = { "ec2:ResourceTag/Environment" = ["cert", "standing", "demo"] } }
      },
      {
        Sid       = "ProtectEc2Lifecycle"
        Effect    = "Deny"
        Action    = "ec2:*"
        Resource  = "*"
        Condition = { StringEquals = { "ec2:ResourceTag/Lifecycle" = ["standing", "demo"] } }
      },
      {
        Sid       = "ProtectEc2Owner"
        Effect    = "Deny"
        Action    = "ec2:*"
        Resource  = "*"
        Condition = { StringEquals = { "ec2:ResourceTag/Owner" = ["release-standing"] } }
      },
      {
        Sid       = "ProtectEc2Demo"
        Effect    = "Deny"
        Action    = "ec2:*"
        Resource  = "*"
        Condition = { StringEquals = { "ec2:ResourceTag/Purpose" = ["public-demo"] } }
      },
      { Sid = "ProtectStandingNames", Effect = "Deny", Action = "*", Resource = local.protected_names },
    ]
  })
}

resource "aws_iam_role" "reaper" {
  name                 = var.role_name
  max_session_duration = var.max_session_duration
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = var.oidc_subjects
      } }
    }]
  })
}

resource "aws_iam_role_policy" "reaper" {
  name   = "validation-reaper"
  role   = aws_iam_role.reaper.id
  policy = local.policy
}

output "role_arn" {
  description = "Set as the honua-iac repository variable HONUA_AWS_VALIDATION_REAPER_ROLE_ARN."
  value       = aws_iam_role.reaper.arn
}

output "policy" { value = local.policy }
