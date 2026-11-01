provider "aws" { region = var.region }

resource "time_static" "created" {}

locals {
  expires = timeadd(time_static.created.rfc3339, "${var.ttl_hours}h")
  tags = {
    Environment  = "it"
    Lifecycle    = "ephemeral"
    Owner        = "ai-arc-eval"
    ManagedBy    = "terraform"
    ExpiresAt    = local.expires
    ExpiresAtUTC = local.expires
  }
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}
resource "aws_vpc" "eval" {
  cidr_block           = "10.87.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "honua-ai-arc-eval" })
}
resource "aws_subnet" "eval" {
  vpc_id                  = aws_vpc.eval.id
  cidr_block              = "10.87.1.0/24"
  map_public_ip_on_launch = true
  tags                    = local.tags
}
resource "aws_internet_gateway" "eval" {
  vpc_id = aws_vpc.eval.id
  tags   = local.tags
}
resource "aws_route_table" "eval" {
  vpc_id = aws_vpc.eval.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eval.id
  }
  tags = local.tags
}
resource "aws_route_table_association" "eval" {
  subnet_id      = aws_subnet.eval.id
  route_table_id = aws_route_table.eval.id
}
resource "aws_security_group" "eval" {
  name_prefix = "honua-ai-arc-eval-"
  description = "SSH access to ephemeral AI evaluation hosts"
  vpc_id      = aws_vpc.eval.id
  ingress {
    description = "SSH from operator networks"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = sort(tolist(var.allowed_ssh_cidrs))
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}
resource "aws_key_pair" "eval" {
  key_name_prefix = "honua-ai-arc-eval-"
  public_key      = trimspace(var.ssh_public_key)
  tags            = local.tags
}
resource "aws_instance" "eval" {
  count                       = var.host_count
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.eval.id
  vpc_security_group_ids      = [aws_security_group.eval.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.eval.key_name
  iam_instance_profile        = length(var.bedrock_model_ids) > 0 ? aws_iam_instance_profile.bedrock[0].name : ""
  user_data                   = file("${path.module}/install-docker.sh")
  user_data_replace_on_change = true
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # Containers on the Docker bridge are one hop further from IMDS; only the
    # opt-in Bedrock profile needs them to reach it.
    http_put_response_hop_limit = length(var.bedrock_model_ids) > 0 ? 2 : 1
  }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 200
    tags        = local.tags
  }
  tags = merge(local.tags, { Name = "honua-ai-arc-eval-${count.index + 1}" })
}

# Opt-in, invoke-only Bedrock access for the stack running on the host (the Studio
# assistant's server-side credentials). The model process never receives it.
data "aws_caller_identity" "current" {
  count = length(var.bedrock_model_ids) > 0 ? 1 : 0
}

data "aws_iam_policy_document" "bedrock_assume" {
  count = length(var.bedrock_model_ids) > 0 ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "bedrock_invoke" {
  count = length(var.bedrock_model_ids) > 0 ? 1 : 0
  statement {
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = concat(
      [for id in var.bedrock_model_ids : "arn:aws:bedrock:*::foundation-model/${id}"],
      [for id in var.bedrock_model_ids : "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current[0].account_id}:inference-profile/us.${id}"],
    )
  }
}

resource "aws_iam_role" "bedrock" {
  count              = length(var.bedrock_model_ids) > 0 ? 1 : 0
  name_prefix        = "honua-ai-arc-eval-bedrock-"
  assume_role_policy = data.aws_iam_policy_document.bedrock_assume[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy" "bedrock" {
  count  = length(var.bedrock_model_ids) > 0 ? 1 : 0
  name   = "bedrock-invoke"
  role   = aws_iam_role.bedrock[0].id
  policy = data.aws_iam_policy_document.bedrock_invoke[0].json
}

resource "aws_iam_instance_profile" "bedrock" {
  count       = length(var.bedrock_model_ids) > 0 ? 1 : 0
  name_prefix = "honua-ai-arc-eval-bedrock-"
  role        = aws_iam_role.bedrock[0].name
  tags        = local.tags
}
