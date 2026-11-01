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

run "bedrock_invoke_only_when_opted_in" {
  command = apply
  variables { bedrock_model_ids = ["anthropic.claude-sonnet-4-6"] }
  override_data {
    target = data.aws_caller_identity.current[0]
    values = { account_id = "123456789012" }
  }
  override_data {
    target = data.aws_iam_policy_document.bedrock_invoke[0]
    values = { json = "{}" }
  }
  override_data {
    target = data.aws_iam_policy_document.bedrock_assume[0]
    values = { json = "{}" }
  }
  assert {
    condition     = length(aws_iam_instance_profile.bedrock) == 1 && alltrue([for host in aws_instance.eval : host.iam_instance_profile == aws_iam_instance_profile.bedrock[0].name])
    error_message = "With bedrock_model_ids set, every host gets the invoke-only profile."
  }
  assert {
    condition     = alltrue([for host in aws_instance.eval : host.metadata_options[0].http_tokens == "required" && host.metadata_options[0].http_put_response_hop_limit == 2])
    error_message = "Opted-in hosts keep IMDSv2 required and allow one container hop."
  }
  assert {
    condition = (
      toset(data.aws_iam_policy_document.bedrock_invoke[0].statement[0].actions) == toset(["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]) &&
      alltrue([for r in data.aws_iam_policy_document.bedrock_invoke[0].statement[0].resources : !strcontains(r, "*::foundation-model/*") && !endswith(r, "/*")])
    )
    error_message = "The Bedrock policy allows only invoke actions on the exact listed models."
  }
}

run "reject_wildcard_model" {
  command = plan
  variables { bedrock_model_ids = ["anthropic.*"] }
  expect_failures = [var.bedrock_model_ids]
}
