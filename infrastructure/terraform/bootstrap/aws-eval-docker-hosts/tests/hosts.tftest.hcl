mock_provider "aws" {}
mock_provider "time" {
  mock_resource "time_static" {
    defaults = { rfc3339 = "2026-10-30T00:00:00Z" }
  }
}

variables {
  allowed_ssh_cidrs = ["192.0.2.1/32"]
  ssh_public_key    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest"
}
run "host_security" {
  command = apply
  assert {
    condition     = length(aws_instance.eval) == 4 && alltrue([for host in aws_instance.eval : host.metadata_options[0].http_tokens == "required" && host.iam_instance_profile == ""])
    error_message = "All hosts must require IMDSv2 and have no instance profile."
  }
  assert {
    condition     = alltrue([for host in aws_instance.eval : host.tags.Environment == "it" && host.tags.Lifecycle == "ephemeral" && host.tags.Owner == "ai-arc-eval" && contains(keys(host.tags), "ExpiresAt") && contains(keys(host.tags), "ExpiresAtUTC")])
    error_message = "Hosts must carry the ephemeral ownership and expiration tags."
  }
  assert {
    condition     = length(aws_security_group.eval.ingress) == 1 && one(aws_security_group.eval.ingress).cidr_blocks == tolist(["192.0.2.1/32"]) && one(aws_security_group.eval.ingress).from_port == 22 && one(aws_security_group.eval.ingress).to_port == 22
    error_message = "Only configured SSH ingress is allowed."
  }
}
run "reject_world_ssh" {
  command = plan
  variables { allowed_ssh_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.allowed_ssh_cidrs]
}
