mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-north-1a", "eu-north-1b", "eu-north-1c"] }
  }
}
override_data {
  target = data.aws_ssm_parameter.github_app_id
  values = { value = "12345" }
}
variables {
  budget_alert_email = "ops@example.com"
}
run "default_has_no_overflow_access" {
  command = apply
  assert {
    condition     = length(aws_security_group.runners.ingress) == 0 && local.overflow_toolchain == "" && local.runner_host_config.runner_count == 12
    error_message = "Overflow must be opt-in without changing the existing pool."
  }
  assert {
    condition     = local.user_data_bytes <= 16384 && aws_launch_template.runners.user_data == base64gzip(local.runner_bootstrap) && startswith(aws_launch_template.runners.user_data, "H4sI")
    error_message = "Default user data must fit the EC2 limit."
  }
}
run "shared_installer_receives_complete_light_runner_configuration" {
  command = apply
  assert {
    condition = length(local.runner_host_config.runners) == var.runner_count && alltrue([
      for runner in local.runner_host_config.runners :
      runner.pool == "light" && runner.group == var.runner_group &&
      contains(runner.labels, "honua-light") && runner.service_containers &&
      runner.cpu_quota_percent == var.runner_cpu_quota_percent &&
      runner.memory_max_gib == var.runner_memory_max_gib && !runner.light_overflow
    ]) && local.runner_host_config.min_free_disk_gib == 40
    error_message = "The shared installer needs a complete isolated service-container account per light runner."
  }
}
run "overflow_reserves_capacity_on_existing_spot_host" {
  command = apply
  variables {
    runner_count    = 10
    pre_pr_overflow = { ssh_cidr = "192.0.2.1/32", ssh_public_key = "ssh-ed25519 AAAATEST operator" }
  }
  assert {
    condition     = one(aws_security_group.runners.ingress).from_port == 22 && one(aws_security_group.runners.ingress).to_port == 22 && length(one(aws_security_group.runners.ingress).cidr_blocks) == 1 && contains(one(aws_security_group.runners.ingress).cidr_blocks, "192.0.2.1/32")
    error_message = "Only restricted operator SSH may be opened."
  }
  assert {
    condition     = local.runner_host_config.runner_count * local.runner_host_config.cpu_quota_percent + 400 <= 3000 && local.runner_host_config.runner_count * local.runner_host_config.memory_max_gib + 8 <= 62
    error_message = "Overflow must reserve CPU, memory and host headroom."
  }
  assert {
    condition     = aws_autoscaling_group.runners.max_size == 1 && one(one(aws_autoscaling_group.runners.mixed_instances_policy).instances_distribution).on_demand_base_capacity == 0 && one(one(aws_autoscaling_group.runners.mixed_instances_policy).instances_distribution).on_demand_percentage_above_base_capacity == 0
    error_message = "Overflow must reuse the single Spot host."
  }
  assert {
    condition     = local.user_data_bytes <= 16384 && aws_launch_template.runners.user_data == base64gzip(local.runner_bootstrap) && startswith(aws_launch_template.runners.user_data, "H4sI")
    error_message = "Overflow SDK and isolation bootstrap must fit the EC2 limit."
  }
}
run "reject_unreserved_default_pool" {
  command = plan
  variables { pre_pr_overflow = { ssh_cidr = "192.0.2.1/32", ssh_public_key = "ssh-ed25519 AAAATEST" } }
  expect_failures = [var.pre_pr_overflow]
}
run "reject_public_ssh" {
  command = plan
  variables {
    runner_count    = 10
    pre_pr_overflow = { ssh_cidr = "0.0.0.0/0", ssh_public_key = "ssh-ed25519 AAAATEST" }
  }
  expect_failures = [var.pre_pr_overflow]
}
run "reject_multiline_authorization" {
  command = plan
  variables {
    runner_count    = 10
    pre_pr_overflow = { ssh_cidr = "192.0.2.1/32", ssh_public_key = "ssh-ed25519 AAAATEST\nssh-ed25519 OTHER" }
  }
  expect_failures = [var.pre_pr_overflow]
}
run "reject_reserved_account_collision" {
  command = plan
  variables {
    runner_count             = 16
    runner_cpu_quota_percent = 100
    runner_memory_max_gib    = 2
    pre_pr_overflow          = { ssh_cidr = "192.0.2.1/32", ssh_public_key = "ssh-ed25519 AAAATEST" }
  }
  expect_failures = [var.pre_pr_overflow]
}
