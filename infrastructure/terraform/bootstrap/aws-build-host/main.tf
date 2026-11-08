provider "aws" { region = var.region }

locals {
  name = "honua-lane-build-host"
  tags = {
    Environment = "it"
    Lifecycle   = "on-demand"
    Owner       = "lane-builds"
    ManagedBy   = "terraform"
  }
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_vpc" "build" {
  cidr_block           = "10.88.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = local.name })
}

resource "aws_subnet" "build" {
  vpc_id                  = aws_vpc.build.id
  cidr_block              = "10.88.1.0/24"
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
  subnet_id      = aws_subnet.build.id
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

# Persistent spot request that stops (keeping the disk and its caches) when capacity is reclaimed.
resource "aws_instance" "build" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.build.id
  vpc_security_group_ids      = [aws_security_group.build.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.build.key_name
  ebs_optimized               = true
  user_data                   = join("\n", [file("${path.module}/../shared/install-docker.sh"), file("${path.module}/install-build-tools.sh")])
  user_data_replace_on_change = true

  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type             = "persistent"
      instance_interruption_behavior = "stop"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = var.root_volume_gib
    iops        = 6000
    throughput  = 500
    tags        = local.tags
  }

  tags = merge(local.tags, { Name = local.name })

  lifecycle {
    ignore_changes = [ami]
  }

  # The installer downloads packages at boot, so outbound routing must exist first.
  depends_on = [aws_route_table_association.build]
}

resource "aws_cloudwatch_metric_alarm" "idle_stop" {
  alarm_name          = "${local.name}-idle-stop"
  alarm_description   = "Stops the lane build host after ${var.idle_stop_minutes} idle minutes."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = aws_instance.build.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = var.idle_stop_minutes / 5
  threshold           = var.idle_cpu_percent
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = ["arn:aws:automate:${var.region}:ec2:stop"]
  tags                = local.tags
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

data "aws_iam_policy_document" "scheduler_stop" {
  statement {
    actions   = ["ec2:StopInstances"]
    resources = [aws_instance.build.arn]
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
  policy = data.aws_iam_policy_document.scheduler_stop.json
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
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [aws_instance.build.id] })
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
