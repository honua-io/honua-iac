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
  iam_instance_profile        = ""
  user_data                   = file("${path.module}/install-docker.sh")
  user_data_replace_on_change = true
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 200
    tags        = local.tags
  }
  tags = merge(local.tags, { Name = "honua-ai-arc-eval-${count.index + 1}" })
}
