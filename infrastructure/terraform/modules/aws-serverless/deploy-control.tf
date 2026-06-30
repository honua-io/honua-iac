###############################################################################
# Deploy control plane — in-VPC reach to the AWS Lambda control API.
#
# The server's coordinated deploy/rollback backend (AwsLambdaGitOpsDeployBackend)
# manages THIS function's `live` alias to roll a published version forward and to
# roll it back. Those are AWS Lambda control-plane calls (lambda:GetAlias /
# lambda:UpdateAlias). On a no-NAT serverless deploy (enable_nat_gateway = false)
# the Lambda runs in private subnets with no default route, so without an
# interface VPC endpoint for the Lambda service those calls have NO network path
# and hang until the function times out — which is exactly why the demo alias
# flip had to be done manually (honua-server#2166: "auto-rollback unwired / demo
# flip manual").
#
# This file closes that gap with two independent pieces:
#
#   1. IAM (ALWAYS): grant the Lambda execution role lambda:GetAlias /
#      lambda:UpdateAlias (+ read helpers) on THIS function so the deploy backend
#      is authorized to manage its own alias. This is required on every deploy
#      target regardless of NAT — without it the backend gets AccessDenied.
#
#   2. NETWORK (no-NAT only): create interface VPC endpoints so the in-VPC
#      control plane can reach the Lambda control API (and CloudWatch metrics /
#      logs used by the health-gated auto-rollback telemetry path). Skipped when
#      enable_nat_gateway = true because NAT already provides that egress.
#
# Cost note: each interface endpoint is ~$7.30/mo/AZ + per-GB. They are created
# only on the no-NAT path, where they are strictly cheaper than a NAT gateway and
# are the only way to reach these services.
###############################################################################

locals {
  # Network endpoints are only needed when there is no NAT egress. With a NAT
  # gateway the public AWS service endpoints are already reachable.
  deploy_control_endpoints_enabled = var.enable_deploy_control_vpc_endpoints && !var.enable_nat_gateway

  # The custom-code egress-isolation feature (egress-isolation.tf) already
  # provisions an STS interface endpoint with private DNS. AWS allows only ONE
  # private-DNS interface endpoint per service per VPC, so only create the STS
  # endpoint here when that feature is not already providing it.
  deploy_control_create_sts = local.deploy_control_endpoints_enabled && !local.egress_isolation_enabled
}

# ---------------------------------------------------------------------------
# IAM — let the deploy backend manage this function's alias (ALWAYS).
#
# Scoped to THIS function (unqualified + qualified ARNs). Never Action="*";
# least-privilege to the alias read/update calls the backend actually makes.
# ---------------------------------------------------------------------------
resource "aws_iam_role_policy" "lambda_deploy_control" {
  name = "${local.name}-lambda-deploy-control"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "HonuaDeployControlAliasManagement"
        Effect = "Allow"
        Action = [
          "lambda:GetAlias",
          "lambda:UpdateAlias",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:ListVersionsByFunction"
        ]
        Resource = [
          aws_lambda_function.this.arn,
          "${aws_lambda_function.this.arn}:*"
        ]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Interface VPC endpoints (no-NAT only).
# ---------------------------------------------------------------------------
#checkov:skip=CKV2_AWS_5: Attached to the deploy-control interface VPC endpoints below.
resource "aws_security_group" "deploy_control_endpoints" {
  count = local.deploy_control_endpoints_enabled ? 1 : 0
  #checkov:skip=CKV2_AWS_5: Attached to the deploy-control interface VPC endpoints below.
  name_prefix = "${local.name}-deploy-vpce-"
  description = "Honua deploy control plane interface VPC endpoint security group (443 from VPC)"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTPS from the VPC (Lambda control API / CloudWatch endpoints)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  egress {
    description = "HTTPS responses within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr_block]
  }

  tags = merge(local.tags, { Name = "${local.name}-deploy-vpce" })
}

# Lambda control API — required for the deploy backend's GetAlias/UpdateAlias.
resource "aws_vpc_endpoint" "lambda" {
  count               = local.deploy_control_endpoints_enabled ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.lambda"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  security_group_ids  = [aws_security_group.deploy_control_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name}-lambda" })
}

# STS — credential/identity calls the AWS SDK may make for control-plane actions.
# Skipped when egress-isolation.tf already provides an STS endpoint (one
# private-DNS endpoint per service per VPC).
resource "aws_vpc_endpoint" "deploy_control_sts" {
  count               = local.deploy_control_create_sts ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  security_group_ids  = [aws_security_group.deploy_control_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name}-deploy-sts" })
}

# CloudWatch metrics — read/write for the health-gated auto-rollback telemetry
# gate (the CloudWatch deploy telemetry provider) and metric publication.
resource "aws_vpc_endpoint" "monitoring" {
  count               = local.deploy_control_endpoints_enabled ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.monitoring"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  security_group_ids  = [aws_security_group.deploy_control_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name}-monitoring" })
}

# CloudWatch Logs — direct log delivery for in-VPC components that write to
# CloudWatch Logs over the API on the no-NAT path.
resource "aws_vpc_endpoint" "logs" {
  count               = local.deploy_control_endpoints_enabled ? 1 : 0
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  security_group_ids  = [aws_security_group.deploy_control_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name}-logs" })
}
