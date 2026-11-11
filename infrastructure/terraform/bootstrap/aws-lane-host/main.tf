provider "aws" { region = var.region }

locals {
  name = "honua-lane-host"
  tags = {
    Environment = "it"
    Lifecycle   = "on-demand"
    Owner       = "lane-agents"
    ManagedBy   = "terraform"
  }
  # Budget usage types carry a region prefix; on-demand Linux compute is BoxUsage.
  usage_type_prefix = { "eu-north-1" = "EUN1-", "us-east-1" = "", "us-east-2" = "USE2-", "us-west-2" = "USW2-", "eu-west-1" = "EU-" }
  host_config = {
    region              = var.region
    parameter_prefix    = var.parameter_prefix
    data_volume_id      = aws_ebs_volume.lanes.id
    claude_code_version = var.claude_code_version
    rtk_version         = var.rtk_version
    rtk_sha256          = var.rtk_sha256
  }
}

module "operator_access" {
  source             = "../../components/operator-host-access"
  allowed_ssh_cidrs  = var.allowed_ssh_cidrs
  ssh_public_key     = var.ssh_public_key
  budget_alert_email = var.budget_alert_email
}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_vpc" "lanes" {
  cidr_block           = "10.89.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = local.name })
}

resource "aws_subnet" "lanes" {
  vpc_id                  = aws_vpc.lanes.id
  cidr_block              = cidrsubnet(aws_vpc.lanes.cidr_block, 8, 16)
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false
  tags                    = local.tags
}

resource "aws_internet_gateway" "lanes" {
  vpc_id = aws_vpc.lanes.id
  tags   = local.tags
}

resource "aws_route_table" "lanes" {
  vpc_id = aws_vpc.lanes.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lanes.id
  }
  tags = local.tags
}

resource "aws_route_table_association" "lanes" {
  subnet_id      = aws_subnet.lanes.id
  route_table_id = aws_route_table.lanes.id
}

resource "aws_security_group" "lanes" {
  name_prefix = "${local.name}-"
  description = "SSH from operator networks to the lane host"
  vpc_id      = aws_vpc.lanes.id
  ingress {
    description = "SSH from operator networks"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = module.operator_access.allowed_ssh_cidrs
  }
  egress {
    description = "Model APIs, Git hosting, package feeds and the build host"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_key_pair" "lanes" {
  key_name_prefix = "${local.name}-"
  public_key      = module.operator_access.ssh_public_key
  tags            = local.tags
}

# Worktrees, logs and lane state outlive the instance: replacing or destroying the host keeps this volume.
resource "aws_ebs_volume" "lanes" {
  availability_zone = var.availability_zone
  size              = var.data_volume_gib
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = true
  tags              = merge(local.tags, { Name = "${local.name}-data" })
  lifecycle { prevent_destroy = true }
}

resource "aws_instance" "lanes" {
  ami                                  = data.aws_ssm_parameter.ubuntu.value
  instance_type                        = var.instance_type
  subnet_id                            = aws_subnet.lanes.id
  associate_public_ip_address          = true
  vpc_security_group_ids               = [aws_security_group.lanes.id]
  key_name                             = aws_key_pair.lanes.key_name
  iam_instance_profile                 = aws_iam_instance_profile.lanes.name
  ebs_optimized                        = true
  instance_initiated_shutdown_behavior = "stop"
  user_data_base64 = base64gzip(join("\n", [
    "#!/bin/bash\nset -euo pipefail",
    "echo '${base64encode(jsonencode(local.host_config))}' | base64 -d > /etc/honua-lane-host.json",
    file("${path.module}/../shared/install-docker.sh"),
    file("${path.module}/install-lane-host.sh"),
  ]))
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted             = true
    delete_on_termination = true
    volume_type           = "gp3"
    volume_size           = var.root_volume_gib
    tags                  = local.tags
  }
  tags = merge(local.tags, { Name = local.name })
  # Running lanes must not be interrupted by a newer AMI or bootstrap; replace the host deliberately.
  lifecycle { ignore_changes = [ami, user_data_base64] }
  depends_on = [aws_route_table_association.lanes]
}

resource "aws_volume_attachment" "lanes" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.lanes.id
  instance_id                    = aws_instance.lanes.id
  stop_instance_before_detaching = true
}

resource "aws_eip" "lanes" {
  domain   = "vpc"
  instance = aws_instance.lanes.id
  tags     = merge(local.tags, { Name = local.name })
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lanes" {
  name_prefix        = "${local.name}-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.tags
}

resource "aws_iam_instance_profile" "lanes" {
  name_prefix = "${local.name}-"
  role        = aws_iam_role.lanes.name
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "session_manager" {
  role       = aws_iam_role.lanes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "lanes" {
  statement {
    sid       = "ReadLaneSecrets"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.parameter_prefix}/*"]
  }
  statement {
    sid       = "FindBuildHost"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
  statement {
    sid       = "WakeBuildHost"
    actions   = ["autoscaling:SetDesiredCapacity"]
    resources = ["arn:aws:autoscaling:${var.region}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.build_host_group_name}"]
  }
}

resource "aws_iam_role_policy" "lanes" {
  name   = "lane-secrets-and-build-host"
  role   = aws_iam_role.lanes.id
  policy = data.aws_iam_policy_document.lanes.json
}

# The build host admits SSH only from listed CIDRs. This rule admits the lane host's fixed address;
# list the same address in the build host's allowed_ssh_cidrs, or its next apply removes this rule.
data "aws_security_group" "build_host" {
  count = var.build_host_ssh_access ? 1 : 0
  filter {
    name   = "group-name"
    values = ["${var.build_host_group_name}-*"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "build_host_from_lanes" {
  count             = var.build_host_ssh_access ? 1 : 0
  security_group_id = data.aws_security_group.build_host[0].id
  description       = "SSH from the lane host"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = "${aws_eip.lanes.public_ip}/32"
}

# Email alert on the lane host's on-demand compute. Budgets data lags several hours; stopping the
# instance is what ends the bill.
resource "aws_budgets_budget" "lane_host" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "UsageType"
    values = ["${lookup(local.usage_type_prefix, var.region, "")}BoxUsage:${var.instance_type}"]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [module.operator_access.budget_alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [module.operator_access.budget_alert_email]
  }
}
