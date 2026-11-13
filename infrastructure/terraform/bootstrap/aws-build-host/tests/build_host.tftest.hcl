mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-north-1a", "eu-north-1b", "eu-north-1c"] }
  }

}

variables {
  allowed_ssh_cidrs  = ["192.0.2.1/32"]
  ssh_public_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest"
  budget_alert_email = "ops@example.com"
}

override_data {
  target = data.aws_iam_policy_document.scheduler_assume
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}
override_data {
  target = data.aws_iam_policy_document.stop_group
  values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

run "spot_host_that_stops_itself" {
  command = apply
  assert {
    condition     = length(regexall("(?s)systemctl enable --now honua-build-host-idle-stop.timer.*curl -fsSL", base64decode(aws_launch_template.build.user_data))) == 1
    error_message = "The dependency-free idle timer must be enabled before network bootstrap."
  }
  assert {
    condition     = aws_subnet.build["eu-north-1c"].cidr_block == "10.88.18.0/24"
    error_message = "Zone c must keep a stable subnet regardless of which other zones are available."
  }
  assert {
    condition     = aws_autoscaling_group.build.min_size == 0 && aws_autoscaling_group.build.max_size == 1 && aws_autoscaling_group.build.desired_capacity == 1
    error_message = "The group must support zero or one build host."
  }
  assert {
    condition     = one(one(aws_autoscaling_group.build.mixed_instances_policy).instances_distribution).on_demand_base_capacity == 0 && one(one(aws_autoscaling_group.build.mixed_instances_policy).instances_distribution).on_demand_percentage_above_base_capacity == 0 && one(one(aws_autoscaling_group.build.mixed_instances_policy).instances_distribution).spot_allocation_strategy == "capacity-optimized"
    error_message = "Only capacity-optimized Spot capacity is allowed."
  }
  assert {
    condition     = toset([for item in one(one(aws_autoscaling_group.build.mixed_instances_policy).launch_template).override : item.instance_type]) == toset(["c6i.24xlarge", "c7i.24xlarge", "m6i.24xlarge", "m7i.24xlarge", "c6a.24xlarge", "m6a.24xlarge", "c7a.24xlarge", "m7a.24xlarge", "r6i.24xlarge", "r7i.24xlarge", "c5.24xlarge", "m5.24xlarge", "c5a.24xlarge", "m5a.24xlarge", "c6in.24xlarge", "r6a.24xlarge"])
    error_message = "All sixteen 32-or-more-vCPU replacement types must be offered."
  }
  assert {
    condition     = length(aws_subnet.build) == 3 && toset([for subnet in aws_subnet.build : subnet.availability_zone]) == toset(data.aws_availability_zones.build.names) && toset(aws_autoscaling_group.build.vpc_zone_identifier) == toset([for subnet in aws_subnet.build : subnet.id])
    error_message = "Every regional availability zone must be available to the group."
  }
  assert {
    condition     = one(aws_launch_template.build.metadata_options).http_tokens == "required" && one(aws_launch_template.build.iam_instance_profile).name == aws_iam_instance_profile.build.name && one(one(aws_launch_template.build.block_device_mappings).ebs).encrypted
    error_message = "The template must require IMDSv2, encrypted storage and the scoped idle-stop role."
  }
  assert {
    condition     = aws_scheduler_schedule.nightly_stop.state == "DISABLED" && one(aws_scheduler_schedule.nightly_stop.target).arn == "arn:aws:scheduler:::aws-sdk:autoscaling:setDesiredCapacity" && jsondecode(one(aws_scheduler_schedule.nightly_stop.target).input).DesiredCapacity == 0 && jsondecode(one(aws_scheduler_schedule.nightly_stop.target).input).AutoScalingGroupName == aws_autoscaling_group.build.name
    error_message = "The disabled-by-default nightly stop must scale the group to zero."
  }
  assert {
    condition     = one(data.aws_iam_policy_document.stop_group.statement).actions == toset(["autoscaling:SetDesiredCapacity"]) && one(data.aws_iam_policy_document.stop_group.statement).resources == toset([aws_autoscaling_group.build.arn]) && aws_iam_role_policy.build.policy == data.aws_iam_policy_document.stop_group.json
    error_message = "The host may only change desired capacity on its own group."
  }
  assert {
    condition     = alltrue([for tag in aws_autoscaling_group.build.tag : tag.propagate_at_launch]) && contains([for tag in aws_autoscaling_group.build.tag : "${tag.key}=${tag.value}"], "Name=honua-lane-build-host")
    error_message = "Stable discovery tags must propagate to replacement instances."
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.build.user_data), "fonts-dejavu-core libatomic1 xmlstarlet skopeo clang zlib1g-dev")
    error_message = "Replacement hosts need the native build/runtime dependencies."
  }
  assert {
    condition     = one(aws_budgets_budget.build_host.cost_filter).name == "Service" && contains(one(aws_budgets_budget.build_host.cost_filter).values, "Amazon Elastic Compute Cloud - Compute") && length(aws_budgets_budget.build_host.notification) == 2
    error_message = "EC2 compute cost must raise budget email alerts."
  }
  assert {
    condition     = length(aws_security_group.build.ingress) == 1 && one(aws_security_group.build.ingress).cidr_blocks == tolist(["192.0.2.1/32"]) && one(aws_security_group.build.ingress).from_port == 22
    error_message = "Only configured SSH ingress is allowed."
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.build.user_data), "OnUnitActiveSec=5min") && strcontains(base64decode(aws_launch_template.build.user_data), "systemctl enable --now honua-build-host-idle-stop.timer") && strcontains(base64decode(aws_launch_template.build.user_data), "ExecStart=/usr/local/sbin/honua-build-host-idle-stop")
    error_message = "User data must install and enable the five-minute idle-stop timer."
  }
  assert {
    condition     = startswith(base64decode(aws_launch_template.build.user_data), "#!/bin/bash") && strcontains(base64decode(aws_launch_template.build.user_data), "apt_retry install -y git")
    error_message = "User data must be the shared Docker installer followed by the build tools."
  }
}

run "nightly_stop_when_enabled" {
  command = apply
  variables { nightly_stop_enabled = true }
  assert {
    condition     = aws_scheduler_schedule.nightly_stop.state == "ENABLED" && one(aws_scheduler_schedule.nightly_stop.target).arn == "arn:aws:scheduler:::aws-sdk:autoscaling:setDesiredCapacity" && jsondecode(one(aws_scheduler_schedule.nightly_stop.target).input).DesiredCapacity == 0
    error_message = "Enabling the nightly stop must scale the group to zero."
  }
}

run "reject_world_ssh" {
  command = plan
  variables { allowed_ssh_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.allowed_ssh_cidrs]
}

run "configured_idle_window" {
  command = apply
  variables { idle_stop_minutes = 10 }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.build.user_data), base64encode(jsonencode({ region = var.region, group = "honua-lane-build-host", idle_seconds = 600 })))
    error_message = "The activity timer must receive the configured idle window and fleet identity."
  }
}

run "zone_subnets_do_not_shift" {
  command = apply
  override_data {
    target = data.aws_availability_zones.build
    values = { names = ["eu-north-1b", "eu-north-1c"] }
  }
  assert {
    condition     = aws_subnet.build["eu-north-1c"].cidr_block == "10.88.18.0/24"
    error_message = "Removing another zone must not renumber the remaining subnets."
  }
}

run "gate_runner_off_by_default" {
  command = apply
  assert {
    condition     = length(aws_iam_role.gate_runner_wake) == 0 && length(aws_ssm_parameter.gate_runner_app) == 0 && length(aws_iam_role_policy.gate_runner_host) == 0 && !strcontains(base64decode(aws_launch_template.build.user_data), "honua-gate-runner") && !strcontains(base64decode(aws_launch_template.build.user_data), "gunzip")
    error_message = "Without gate_runner_enabled the host must not register runners or gain registration access."
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.build.user_data), "if command == \"Runner.Worker\":")
    error_message = "A running gate job must count as build activity for the idle stop."
  }
}

run "gate_runner_enabled" {
  command = apply
  variables { gate_runner_enabled = true }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.build.user_data), "source <(base64 -d <<< '${base64gzip(local.gated_build_bootstrap)}' | gunzip)") && local.gated_build_bootstrap == join("\n", [file("../shared/install-docker.sh"), file("install-build-tools.sh"), local.gate_runner_bootstrap]) && strcontains(local.gate_runner_bootstrap, jsonencode(local.gate_runner_host_config)) && endswith(local.gate_runner_bootstrap, file("install-gate-runner.sh"))
    error_message = "The enabled host must install the runner services with their configuration."
  }
  assert {
    condition     = length(base64decode(aws_launch_template.build.user_data)) <= 16384
    error_message = "EC2 user data must stay within 16 KiB."
  }
  assert {
    condition     = jsondecode(aws_iam_role.gate_runner_wake[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:honua-io/honua-server:pull_request" && jsondecode(aws_iam_role.gate_runner_wake[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "Only honua-server pull_request workflows may assume the wake role."
  }
  assert {
    condition     = toset([for statement in jsondecode(aws_iam_role_policy.gate_runner_wake[0].policy).Statement : statement.Action]) == toset(["autoscaling:DescribeAutoScalingGroups", "autoscaling:SetDesiredCapacity", "ssm:GetParameter"]) && contains([for statement in jsondecode(aws_iam_role_policy.gate_runner_wake[0].policy).Statement : statement.Resource if statement.Action == "autoscaling:SetDesiredCapacity"], aws_autoscaling_group.build.arn)
    error_message = "The wake role may only read the group and heartbeat and set this group's capacity."
  }
  assert {
    condition     = toset([for statement in jsondecode(aws_iam_role_policy.gate_runner_host[0].policy).Statement : "${statement.Action}=${statement.Resource}"]) == toset(["ssm:GetParameter=${aws_ssm_parameter.gate_runner_app[0].arn}", "ssm:PutParameter=${aws_ssm_parameter.gate_runner_heartbeat[0].arn}"])
    error_message = "The host may only read the App credential and write its heartbeat."
  }
  assert {
    condition     = aws_ssm_parameter.gate_runner_app[0].type == "SecureString" && aws_ssm_parameter.gate_runner_app[0].value == "unset"
    error_message = "Terraform creates only an encrypted placeholder for the App credential."
  }
}

run "maximum_runner_pool_fits_user_data" {
  command = apply
  variables {
    gate_runner_enabled = true
    gate_runner_count   = 4
    heavy_runner_count  = 8
  }
  assert {
    condition     = local.gate_runner_host_config.runner_count == 12 && length(base64decode(aws_launch_template.build.user_data)) <= 16384
    error_message = "The maximum supported runner pool must fit EC2's 16 KiB user-data limit."
  }
}

run "heavy_runners_follow_the_gate_runners" {
  command = apply
  variables {
    gate_runner_enabled = true
    heavy_runner_count  = 8
  }
  assert {
    condition     = local.gate_runner_host_config.runner_count == 10 && [for runner in local.build_host_runners : runner.pool] == concat(["gate", "gate"], [for _ in range(8) : "heavy"])
    error_message = "Runner N is element N-1: the PR Gate runners first, then the heavy runners."
  }
  assert {
    condition     = alltrue([for runner in local.build_host_runners : runner.group == "honua-heavy" && contains(runner.labels, "honua-heavy") && !contains(runner.labels, "honua-build") && runner.cpu_quota_percent == 800 && runner.memory_max_gib == 16 if runner.pool == "heavy"])
    error_message = "Heavy runners join only the honua-heavy group and label with eight vCPUs and 16 GiB each."
  }
  assert {
    condition     = length(base64decode(aws_launch_template.build.user_data)) <= 16384
    error_message = "EC2 user data must stay within 16 KiB."
  }
}

run "only_heavy_runners_start_service_containers" {
  command = apply
  variables { gate_runner_enabled = true }
  assert {
    condition     = alltrue([for runner in local.build_host_runners : runner.service_containers == (runner.pool == "heavy")])
    error_message = "Only heavy runners expose /proc/1/cgroup for service containers; PR Gate runners keep ProtectProc=invisible."
  }
}
