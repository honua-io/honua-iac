# One Spot host of ephemeral one-job GitHub Actions runners for light CI jobs, built from the
# build host's gate runner bootstrap: per-runner rootless Docker, a pristine home per job,
# no route to instance metadata from jobs and a just-in-time registration for one job.

provider "aws" { region = var.region }

locals {
  name = "honua-light-runners"
  tags = {
    Environment = "it"
    Lifecycle   = "spot"
    Owner       = "light-runners"
    ManagedBy   = "terraform"
  }
  app_parameter       = "/${local.name}/github-app"
  heartbeat_parameter = "/${local.name}/heartbeat"
  runner_host_config = {
    region              = var.region
    org                 = "honua-io"
    group               = var.runner_group
    labels              = ["self-hosted", "linux", "x64", "honua-light"]
    runner_count        = var.runner_count
    cpu_quota_percent   = var.runner_cpu_quota_percent
    memory_max_gib      = var.runner_memory_max_gib
    runner_version      = "2.338.2"
    runner_sha256       = "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"
    app_parameter       = local.app_parameter
    heartbeat_parameter = local.heartbeat_parameter
  }
  build_host = "${path.module}/../aws-build-host"
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_availability_zones" "runners" {
  state = "available"
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

resource "aws_vpc" "runners" {
  cidr_block           = "10.89.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = local.name })
}

resource "aws_subnet" "runners" {
  for_each                = toset(data.aws_availability_zones.runners.names)
  vpc_id                  = aws_vpc.runners.id
  cidr_block              = cidrsubnet(aws_vpc.runners.cidr_block, 8, index(split("", "abcdefghijklmnopqrstuvwxyz"), substr(each.key, -1, 1)) + 16)
  availability_zone       = each.key
  map_public_ip_on_launch = true
  tags                    = local.tags
}

resource "aws_internet_gateway" "runners" {
  vpc_id = aws_vpc.runners.id
  tags   = local.tags
}

resource "aws_route_table" "runners" {
  vpc_id = aws_vpc.runners.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.runners.id
  }
  tags = local.tags
}

resource "aws_route_table_association" "runners" {
  for_each       = aws_subnet.runners
  subnet_id      = each.value.id
  route_table_id = aws_route_table.runners.id
}

# No inbound rules: operators reach the host through SSM Session Manager.
resource "aws_security_group" "runners" {
  name_prefix = "${local.name}-"
  description = "Light runner host: no inbound, outbound to GitHub, package feeds and registries"
  vpc_id      = aws_vpc.runners.id
  egress {
    description = "GitHub, package feeds and container registries"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

data "aws_ssm_parameter" "github_app_id" {
  name = var.github_app_id_parameter
}

ephemeral "aws_ssm_parameter" "github_app_key" {
  arn             = "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.github_app_key_parameter}"
  with_decryption = true
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# The registration script reads {"app_id", "private_key"} from one root-only parameter.
resource "aws_ssm_parameter" "github_app" {
  name        = local.app_parameter
  description = "GitHub App credential that mints single-job light runner registrations; readable only by the runner host."
  type        = "SecureString"
  value_wo = jsonencode({
    app_id      = tonumber(data.aws_ssm_parameter.github_app_id.value)
    private_key = ephemeral.aws_ssm_parameter.github_app_key.value
  })
  value_wo_version = var.github_app_credential_version
  tags             = local.tags
}

resource "aws_ssm_parameter" "heartbeat" {
  name        = local.heartbeat_parameter
  description = "Light runner host readiness: instance, epoch seconds and idle runners."
  type        = "String"
  value       = "{}"
  tags        = local.tags
  lifecycle { ignore_changes = [value] }
}

resource "aws_iam_role" "runners" {
  name_prefix = "${local.name}-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
  tags = local.tags
}

resource "aws_iam_instance_profile" "runners" {
  name_prefix = "${local.name}-"
  role        = aws_iam_role.runners.name
  tags        = local.tags
}

# Session Manager without AmazonSSMManagedInstanceCore, which would also allow reading every parameter.
resource "aws_iam_role_policy" "runners" {
  name = "light-runner-host"
  role = aws_iam_role.runners.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ssm:GetParameter", Resource = aws_ssm_parameter.github_app.arn },
      { Effect = "Allow", Action = "ssm:PutParameter", Resource = aws_ssm_parameter.heartbeat.arn },
      {
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
          "ec2messages:AcknowledgeMessage", "ec2messages:DeleteMessage", "ec2messages:FailMessage",
          "ec2messages:GetEndpoint", "ec2messages:GetMessages", "ec2messages:SendReply"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_launch_template" "runners" {
  name_prefix   = "${local.name}-"
  image_id      = data.aws_ssm_parameter.ubuntu.value
  ebs_optimized = true
  user_data = base64encode(join("\n", [
    "#!/bin/bash\nset -euo pipefail",
    file("${local.build_host}/../shared/install-docker.sh"),
    "apt_retry install -y git rsync python3 python3-venv unzip jq",
    "(umask 077 && echo '${base64encode(jsonencode(local.runner_host_config))}' | base64 -d > /etc/honua-gate-runner.json)",
    # Compressed and sourced to stay under the 16 KiB EC2 limit with apt_retry in scope.
    "source <(base64 -d <<< '${base64gzip(file("${local.build_host}/install-gate-runner.sh"))}' | gunzip)"
  ]))
  iam_instance_profile { name = aws_iam_instance_profile.runners.name }
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.runners.id]
    delete_on_termination       = true
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      encrypted             = true
      delete_on_termination = true
      volume_type           = "gp3"
      volume_size           = var.root_volume_gib
      iops                  = 6000
      throughput            = 500
    }
  }
  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }
  tags = local.tags
  lifecycle { ignore_changes = [image_id] }
}

resource "aws_autoscaling_group" "runners" {
  name                = local.name
  min_size            = 0
  max_size            = 1
  desired_capacity    = 1
  capacity_rebalance  = true
  vpc_zone_identifier = [for subnet in aws_subnet.runners : subnet.id]
  # A Spot shortage must not block Terraform; the group keeps trying other pools.
  wait_for_capacity_timeout = "0"
  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.runners.id
        version            = aws_launch_template.runners.latest_version
      }
      dynamic "override" {
        for_each = toset(var.instance_types)
        content { instance_type = override.value }
      }
    }
  }
  dynamic "tag" {
    for_each = merge(local.tags, { Name = local.name })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
  depends_on = [aws_route_table_association.runners, aws_iam_role_policy.runners]
}

# Cost tags are not activated in this account, so the budget scopes by region and instance type;
# no other host here uses these types. Alerts lag several hours and do not stop the host.
resource "aws_budgets_budget" "runners" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "Service"
    values = ["Amazon Elastic Compute Cloud - Compute"]
  }
  cost_filter {
    name   = "Region"
    values = [var.region]
  }
  cost_filter {
    name   = "InstanceType"
    values = var.instance_types
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
