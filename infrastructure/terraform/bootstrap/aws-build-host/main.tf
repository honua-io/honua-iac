provider "aws" { region = var.region }

locals {
  name = "honua-lane-build-host"
  tags = {
    Environment = "it"
    Lifecycle   = "spot"
    Owner       = "lane-builds"
    ManagedBy   = "terraform"
  }
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_availability_zones" "build" {
  state = "available"
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

resource "aws_vpc" "build" {
  cidr_block           = "10.88.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = local.name })
}

resource "aws_subnet" "build" {
  for_each                = toset(data.aws_availability_zones.build.names)
  vpc_id                  = aws_vpc.build.id
  cidr_block              = cidrsubnet(aws_vpc.build.cidr_block, 8, index(split("", "abcdefghijklmnopqrstuvwxyz"), substr(each.key, -1, 1)) + 16)
  availability_zone       = each.key
  map_public_ip_on_launch = true
  tags                    = local.tags
}

resource "aws_internet_gateway" "build" {
  vpc_id = aws_vpc.build.id
  tags   = local.tags
}

resource "aws_route_table" "build" {
  vpc_id = aws_vpc.build.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.build.id
  }
  tags = local.tags
}

resource "aws_route_table_association" "build" {
  for_each       = aws_subnet.build
  subnet_id      = each.value.id
  route_table_id = aws_route_table.build.id
}

resource "aws_security_group" "build" {
  name_prefix = "${local.name}-"
  description = "SSH from operator networks to the lane build host"
  vpc_id      = aws_vpc.build.id
  ingress {
    description = "SSH from operator networks"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = sort(tolist(var.allowed_ssh_cidrs))
  }
  egress {
    description = "Package feeds, Git hosting and container registries"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_key_pair" "build" {
  key_name_prefix = "${local.name}-"
  public_key      = trimspace(var.ssh_public_key)
  tags            = local.tags
}

resource "aws_launch_template" "build" {
  name_prefix   = "${local.name}-"
  image_id      = data.aws_ssm_parameter.ubuntu.value
  key_name      = aws_key_pair.build.key_name
  ebs_optimized = true
  user_data = base64encode(join("\n", concat([
    "#!/bin/bash\nset -euo pipefail",
    "echo '${base64encode(jsonencode({ region = var.region, group = local.name, idle_seconds = var.idle_stop_minutes * 60 }))}' | base64 -d > /etc/honua-build-host.json",
    var.gate_runner_enabled ? "source <(base64 -d <<< '${base64gzip(file("${path.module}/install-idle-stop.sh"))}' | gunzip)" : file("${path.module}/install-idle-stop.sh")
    ], var.gate_runner_enabled ? [
    # Compress provisioning together; sourcing preserves apt_retry and startup order.
    "source <(base64 -d <<< '${base64gzip(local.gated_build_bootstrap)}' | gunzip)"
    ] : [
    file("${path.module}/../shared/install-docker.sh"),
    file("${path.module}/install-build-tools.sh")
  ])))
  iam_instance_profile { name = aws_iam_instance_profile.build.name }
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.build.id]
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

resource "aws_autoscaling_group" "build" {
  name                = local.name
  min_size            = 0
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [for subnet in aws_subnet.build : subnet.id]
  # A Spot shortage must not block Terraform; the group continues trying other pools.
  wait_for_capacity_timeout = "0"
  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.build.id
        version            = aws_launch_template.build.latest_version
      }
      dynamic "override" {
        for_each = toset(["c6i.24xlarge", "c7i.24xlarge", "m6i.24xlarge", "m7i.24xlarge", "c6a.24xlarge", "m6a.24xlarge", "c7a.24xlarge", "m7a.24xlarge", "r6i.24xlarge", "r7i.24xlarge", "c5.24xlarge", "m5.24xlarge", "c5a.24xlarge", "m5a.24xlarge", "c6in.24xlarge", "r6a.24xlarge"])
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
  # Runtime wake/idle actions own capacity; an apply must not wake an idle host.
  lifecycle { ignore_changes = [desired_capacity] }
  depends_on = [aws_route_table_association.build]
}

resource "aws_iam_role" "build" {
  name_prefix = "${local.name}-idle-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
  tags = local.tags
}

resource "aws_iam_instance_profile" "build" {
  name_prefix = "${local.name}-"
  role        = aws_iam_role.build.name
  tags        = local.tags
}

resource "aws_iam_role_policy" "build" {
  name   = "idle-stop-own-group"
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.stop_group.json
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "stop_group" {
  statement {
    actions   = ["autoscaling:SetDesiredCapacity"]
    resources = [aws_autoscaling_group.build.arn]
  }
}

resource "aws_iam_role" "scheduler" {
  name_prefix        = "${local.name}-stop-"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "stop-build-host"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.stop_group.json
}

resource "aws_scheduler_schedule" "nightly_stop" {
  state                        = var.nightly_stop_enabled ? "ENABLED" : "DISABLED"
  name                         = "${local.name}-nightly-stop"
  schedule_expression          = var.nightly_stop_cron
  schedule_expression_timezone = var.nightly_stop_timezone
  flexible_time_window {
    mode = "OFF"
  }
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:autoscaling:setDesiredCapacity"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ AutoScalingGroupName = aws_autoscaling_group.build.name, DesiredCapacity = 0, HonorCooldown = false })
  }
}

# Email alert on EC2 compute cost. Budgets data lags several hours, so this is a warning,
# not a stop: the idle and nightly stops above are what bound the bill.
resource "aws_budgets_budget" "build_host" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "Service"
    values = ["Amazon Elastic Compute Cloud - Compute"]
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
