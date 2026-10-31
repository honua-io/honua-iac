data "aws_caller_identity" "current" {}

locals {
  boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.name}-workload-boundary"
  template_vars = {
    account_id            = data.aws_caller_identity.current.account_id
    region                = var.region
    boundary_arn          = local.boundary_arn
    mirror_repository_arn = var.mirror_repository_arn
  }
  guardrails = jsondecode(templatefile("${path.module}/policies/guardrails.json.tftpl", local.template_vars)).Statement
  # Opt-in only. Route 53 does not evaluate resource tags, so the zone id and the
  # record-name condition are the DNS boundary. Do not point this at a standing
  # or demo zone. The tag guardrail still denies tagged ACM and API Gateway resources.
  cert_demo_record_names = ["*.cert.demo.honua.io"]
  cert_demo_zone_arn     = "arn:aws:route53:::hostedzone/${var.cert_demo_hosted_zone_id}"
  cert_demo_request_tags = {
    StringEquals = { "aws:RequestTag/Owner" = "release-cell" }
    StringLike   = { "aws:RequestTag/ValidationRunId" = "gha-?*" }
  }
  cert_demo_resource_tags = {
    StringEquals = { "aws:ResourceTag/Owner" = "release-cell" }
    Null         = { "aws:ResourceTag/ValidationRunId" = "false" }
  }
  cert_demo_change = {
    Sid      = "ChangeCertDemoRecords"
    Effect   = "Allow"
    Action   = ["route53:ChangeResourceRecordSets"]
    Resource = local.cert_demo_zone_arn
    Condition = {
      "ForAllValues:StringLike" = { "route53:ChangeResourceRecordSetsNormalizedRecordNames" = local.cert_demo_record_names }
      Null                      = { "route53:ChangeResourceRecordSetsNormalizedRecordNames" = "false" }
    }
  }
  cert_demo_read = {
    Sid      = "ReadCertDemoZone"
    Effect   = "Allow"
    Action   = ["route53:GetChange", "route53:ListResourceRecordSets", "route53:GetHostedZone"]
    Resource = [local.cert_demo_zone_arn, "arn:aws:route53:::change/*"]
  }
  cert_demo_provision = jsonencode([
    local.cert_demo_change,
    local.cert_demo_read,
    {
      Sid       = "RequestCellCertificate"
      Effect    = "Allow"
      Action    = ["acm:RequestCertificate"]
      Resource  = "*"
      Condition = local.cert_demo_request_tags
    },
    {
      Sid       = "ManageCellCertificate"
      Effect    = "Allow"
      Action    = ["acm:AddTagsToCertificate", "acm:DeleteCertificate", "acm:DescribeCertificate", "acm:ListTagsForCertificate"]
      Resource  = "*"
      Condition = local.cert_demo_resource_tags
    },
    {
      Sid       = "CreateCellDomainName"
      Effect    = "Allow"
      Action    = ["apigateway:POST"]
      Resource  = "arn:aws:apigateway:${var.region}::/domainnames"
      Condition = local.cert_demo_request_tags
    },
    {
      Sid       = "ConfigureCellDomainName"
      Effect    = "Allow"
      Action    = ["apigateway:POST", "apigateway:PATCH"]
      Resource  = "arn:aws:apigateway:${var.region}::/domainnames/*"
      Condition = local.cert_demo_resource_tags
    },
    {
      Sid       = "DeleteCellDomainName"
      Effect    = "Allow"
      Action    = ["apigateway:DELETE"]
      Resource  = "arn:aws:apigateway:${var.region}::/domainnames/*"
      Condition = local.cert_demo_resource_tags
    },
  ])
  cert_demo_reaper = jsonencode([
    local.cert_demo_change,
    local.cert_demo_read,
    {
      Sid       = "DeleteCellCertificate"
      Effect    = "Allow"
      Action    = ["acm:DescribeCertificate", "acm:DeleteCertificate"]
      Resource  = "*"
      Condition = local.cert_demo_resource_tags
    },
    {
      Sid       = "DeleteCellDomainName"
      Effect    = "Allow"
      Action    = ["apigateway:DELETE"]
      Resource  = "arn:aws:apigateway:${var.region}::/domainnames/*"
      Condition = local.cert_demo_resource_tags
    },
  ])
  lane_policies = { for lane in ["provision", "reaper", "mirror"] : lane => jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [for statement in jsondecode(templatefile("${path.module}/policies/${lane}.json.tftpl", local.template_vars)).Statement : statement if statement.Sid != "PassCellRoles" || var.enable_workload_role_passing],
      jsondecode(var.cert_demo_hosted_zone_id == "" || lane == "mirror" ? "[]" : (lane == "provision" ? local.cert_demo_provision : local.cert_demo_reaper)),
      local.guardrails,
    )
  }) }
  # The cert demo grants are a managed policy per lane, not inline: with them the provision
  # role's inline policies exceed IAM's 10,240-byte aggregate quota. lane_policies keeps the
  # full effective policy for the simulator.
  cert_demo_policies = var.cert_demo_hosted_zone_id == "" ? {} : {
    provision = jsonencode({ Version = "2012-10-17", Statement = jsondecode(local.cert_demo_provision) })
    reaper    = jsonencode({ Version = "2012-10-17", Statement = jsondecode(local.cert_demo_reaper) })
  }
  cert_demo_sids = toset([for statement in concat(jsondecode(local.cert_demo_provision), jsondecode(local.cert_demo_reaper)) : statement.Sid])
  grant_policies = { for lane, policy in local.lane_policies : lane => jsonencode({
    Version   = "2012-10-17"
    Statement = [for statement in jsondecode(policy).Statement : statement if statement.Effect == "Allow" && !contains(local.cert_demo_sids, statement.Sid)]
  }) }
  guardrail_policy = jsonencode({ Version = "2012-10-17", Statement = local.guardrails })
  runtime_boundary = jsonencode({
    Version = "2012-10-17"
    Statement = concat([for statement in jsondecode(templatefile("${path.module}/policies/runtime.json.tftpl", local.template_vars)).Statement :
      merge(statement, contains(["CellVpcNetworking", "CreateCellVpcNetworkInterface"], statement.Sid) ? { Condition = { ArnEquals = { "ec2:Vpc" = var.workload_vpc_arns } } } : {})
      if !contains(["CellVpcNetworking", "CreateCellVpcNetworkInterface", "NewCellNetworkInterface"], statement.Sid) || length(var.workload_vpc_arns) > 0
      ], [for statement in local.guardrails :
      # The cell roles need Route 53's global endpoint. The workload boundary does not.
      jsondecode(statement.Sid == "CertificationRegionOnly" ? jsonencode(merge(statement, { NotAction = ["iam:*", "sts:*"] })) : jsonencode(statement))
      if !contains(["ProtectBoundary", "NeverRemoveBoundary", "RequireBoundary", "NoRetaggingOwner", "NoStandingCreation", "NoStandingLifecycle"], statement.Sid)
      ],
      length(var.runtime_bedrock_model_arns) == 0 ? [] : [{
        Sid      = "InvokeApprovedBedrockModels"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = var.runtime_bedrock_model_arns
      }],
      # The operator-owned key-ring certificate lives outside the cell namespaces (it must
      # outlive every cell), so CellRuntime's honuar*/honuan* secret ceiling would deny it.
      length(var.runtime_operation_key_ring_certificate_secret_arns) == 0 ? [] : [{
        Sid      = "ReadOperationKeyRingCertificate"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.runtime_operation_key_ring_certificate_secret_arns
      }],
      length(var.runtime_operation_key_ring_certificate_kms_key_arns) == 0 ? [] : [{
        Sid      = "DecryptOperationKeyRingCertificate"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = var.runtime_operation_key_ring_certificate_kms_key_arns
      }],
      # The operator-owned audit hash-chain key likewise outlives every cell.
      length(var.runtime_audit_chain_key_secret_arns) == 0 ? [] : [{
        Sid      = "ReadAuditChainKey"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.runtime_audit_chain_key_secret_arns
      }]
    )
  })
}

resource "aws_iam_policy" "workload_boundary" {
  lifecycle {
    precondition {
      condition = alltrue([for arn, vpc in data.aws_vpc.workload :
        startswith(arn, "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc/") &&
        try(vpc.tags.Owner, "") == "release-cell" &&
        length(try(vpc.tags.ValidationRunId, "")) > 0 &&
        !contains(["cert", "standing", "demo"], try(vpc.tags.Environment, "")) &&
        !contains(["standing", "demo"], try(vpc.tags.Lifecycle, ""))
      ])
      error_message = "Every networking allowlist VPC must belong to a tagged ephemeral cell in this account/region."
    }
  }
  name   = "${var.name}-workload-boundary"
  policy = local.runtime_boundary
}

resource "aws_iam_role" "cell" {
  for_each = local.lane_policies
  name     = "${var.name}-${each.key}"
  # The reaper's sweep waits on RDS/ElastiCache deletion and requests a 7200 s session
  # (honua-release release-cell-reaper.yml); the other lanes stay at one hour.
  max_session_duration = each.key == "reaper" ? 7200 : 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = var.oidc_subjects[each.key]
      } }
    }]
  })
}

resource "aws_iam_role_policy" "cell" {
  for_each = local.grant_policies
  role     = aws_iam_role.cell[each.key].id
  name     = "cell-permissions"
  policy   = each.value
}

output "role_arns" { value = { for lane, role in aws_iam_role.cell : lane => role.arn } }
output "permissions_boundary_arn" { value = aws_iam_policy.workload_boundary.arn }
output "policies" { value = local.lane_policies }
output "runtime_boundary" { value = local.runtime_boundary }

resource "aws_iam_policy" "guardrails" {
  name   = "${var.name}-guardrails"
  policy = local.guardrail_policy
}
resource "aws_iam_role_policy_attachment" "guardrails" {
  for_each   = local.lane_policies
  role       = aws_iam_role.cell[each.key].name
  policy_arn = aws_iam_policy.guardrails.arn
}
resource "aws_iam_policy" "cert_demo" {
  for_each = local.cert_demo_policies
  name     = "${var.name}-cert-demo-${each.key}"
  policy   = each.value
}
resource "aws_iam_role_policy_attachment" "cert_demo" {
  for_each   = local.cert_demo_policies
  role       = aws_iam_role.cell[each.key].name
  policy_arn = aws_iam_policy.cert_demo[each.key].arn
}
data "aws_vpc" "workload" {
  for_each = var.workload_vpc_arns
  id       = split("/", each.value)[1]
}
