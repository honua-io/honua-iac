variables {
  allowed_ssh_cidrs  = ["192.0.2.1/32"]
  ssh_public_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest"
  budget_alert_email = "ops@example.com"
}

run "valid_inputs_pass_through" {
  command = plan
  assert {
    condition     = output.allowed_ssh_cidrs == tolist(["192.0.2.1/32"])
    error_message = "Valid CIDRs must pass through unchanged."
  }
}

run "broad_ssh_source_is_rejected" {
  command = plan
  variables {
    allowed_ssh_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.allowed_ssh_cidrs]
}

run "malformed_public_key_is_rejected" {
  command = plan
  variables {
    ssh_public_key = "not-a-key"
  }
  expect_failures = [var.ssh_public_key]
}
