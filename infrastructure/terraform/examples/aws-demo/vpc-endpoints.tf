###############################################################################
# VPC endpoints — replace the NAT gateway for the demo's AWS-service traffic.
#
# The demo runs with enable_nat_gateway = false (no general egress needed —
# no OIDC, no outbound integrations). The Lambda still resolves
# `aws:secretsmanager:` environment references at runtime, so Secrets Manager
# must stay reachable from the private subnets:
#
#   - Secrets Manager INTERFACE endpoint (~$7.30/mo + per-GB). Single-AZ on
#     purpose: one ENI is enough for demo traffic; cross-AZ hops from the
#     other private subnets are fine.
#   - S3 GATEWAY endpoint (free) on the private route tables, for future COG
#     (Cloud-Optimized GeoTIFF) serving from S3.
#
# When the AI demo is on (enable_bedrock_ai = true) the server calls Amazon
# Bedrock in us-west-2. With no NAT and no default route, the only path to the
# Bedrock runtime is a bedrock-runtime INTERFACE endpoint in this VPC — added
# below, gated on enable_bedrock_ai.
###############################################################################

resource "aws_security_group" "vpc_endpoints" {
  #checkov:skip=CKV2_AWS_5: Attached to the Secrets Manager interface endpoint below.
  name_prefix = "${var.name_prefix}-${var.environment}-vpce-"
  description = "Allow HTTPS to interface VPC endpoints from inside the VPC"
  vpc_id      = module.honua.vpc_id

  ingress {
    description = "HTTPS from the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  tags = local.common_tags
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = module.honua.vpc_id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [module.honua.private_subnet_ids[0]] # single AZ to save cost
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${var.environment}-secretsmanager" })
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.honua.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.honua.private_route_table_ids

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${var.environment}-s3" })
}

# ---------------------------------------------------------------------------
# Bedrock runtime interface endpoint — only when the AI demo is enabled.
#
# This no-NAT VPC has no default route, so the Lambda cannot reach the public
# Bedrock runtime endpoint. com.amazonaws.<region>.bedrock-runtime as an
# interface endpoint (with private DNS) makes bedrock-runtime.<region>.
# amazonaws.com resolve to in-VPC ENIs. bedrock_ai_region must equal var.region
# (the VPC's region) — an interface endpoint can only front a service in its own
# region, and the WorkflowGeneration provider invokes Bedrock in that same
# region. Live id: vpce-003090af73dc835fe (SG sg-0ac55474b410c5d34) — adopt both
# with `terraform import` (see README → "Import the Bedrock VPC endpoint").
# ---------------------------------------------------------------------------

resource "aws_security_group" "bedrock_endpoint" {
  #checkov:skip=CKV2_AWS_5: Attached to the bedrock-runtime interface endpoint below.
  count       = var.enable_bedrock_ai ? 1 : 0
  name_prefix = "${var.name_prefix}-${var.environment}-bedrock-vpce-"
  description = "Allow HTTPS to the Bedrock runtime interface VPC endpoint from inside the VPC"
  vpc_id      = module.honua.vpc_id

  ingress {
    description = "HTTPS from the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  tags = local.common_tags
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  count               = var.enable_bedrock_ai ? 1 : 0
  vpc_id              = module.honua.vpc_id
  service_name        = "com.amazonaws.${var.bedrock_ai_region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [module.honua.private_subnet_ids[0]] # single AZ to save cost
  security_group_ids  = [aws_security_group.bedrock_endpoint[0].id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${var.environment}-bedrock-runtime" })
}
