# Trust scoping of the GitHub OIDC roles.
#
# The policy documents are rendered by the real AWS provider (a local
# computation), with fake static credentials and every account lookup
# overridden, so the plan never reaches AWS. Nothing is applied.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/terraform-test"
    user_id    = "AIDATEST"
  }
}

override_data {
  target = data.aws_region.current
  values = {
    name = "us-east-1"
    id   = "us-east-1"
  }
}

variables {
  create_oidc_provider       = false
  existing_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
}

run "default_subject_is_exact_trunk_ref" {
  command = plan

  assert {
    condition     = tolist(local.oidc_subjects) == tolist(["repo:honua-io/honua-server:ref:refs/heads/trunk"])
    error_message = "The default subject must pin the trunk ref, not repo:<owner>/<repo>:*."
  }

  assert {
    condition = jsondecode(data.aws_iam_policy_document.trust.json).Statement[0].Condition == {
      StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = "repo:honua-io/honua-server:ref:refs/heads/trunk"
      }
    }
    error_message = "Audience and subject must both be StringEquals, with no StringLike condition."
  }

  assert {
    condition     = length(aws_iam_role.hosted_pilot_bootstrap) == 0
    error_message = "The hosted-pilot bootstrap role must be opt-in."
  }
}

run "environment_subject" {
  command = plan

  variables {
    github_oidc_environment = "cert"
  }

  assert {
    condition     = tolist(local.oidc_subjects) == tolist(["repo:honua-io/honua-server:environment:cert"])
    error_message = "github_oidc_environment must pin the exact environment subject."
  }
}

run "explicit_subjects_override" {
  command = plan

  variables {
    github_oidc_subjects = ["repo:honua-io/honua-server:environment:cert"]
  }

  assert {
    condition     = tolist(local.oidc_subjects) == tolist(["repo:honua-io/honua-server:environment:cert"])
    error_message = "github_oidc_subjects must override the computed default."
  }
}

run "wildcard_subjects_are_refused" {
  command = plan

  variables {
    github_oidc_subjects = ["repo:honua-io/honua-server:*"]
  }

  expect_failures = [var.github_oidc_subjects]
}

run "hosted_pilot_bootstrap_role" {
  command = plan

  variables {
    hosted_pilot_bootstrap_role_enabled = true
    hosted_pilot_bootstrap_policy_arns  = ["arn:aws:iam::123456789012:policy/honua-hosted-pilot-foundation-executor"]
  }

  assert {
    condition = jsondecode(data.aws_iam_policy_document.hosted_pilot_bootstrap_trust[0].json).Statement[0].Condition == {
      StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = "repo:honua-io/honua-iac:environment:terraform-ephemeral"
      }
    }
    error_message = "The executor trust must be exactly honua-iac's terraform-ephemeral environment."
  }

  assert {
    condition     = aws_iam_role.hosted_pilot_bootstrap[0].name == "honua-hosted-pilot-bootstrap-gha" && aws_iam_role.hosted_pilot_bootstrap[0].max_session_duration == 3600
    error_message = "The executor role keeps its protected -gha name and a one-hour session ceiling."
  }

  assert {
    condition     = keys(aws_iam_role_policy_attachment.hosted_pilot_bootstrap) == ["arn:aws:iam::123456789012:policy/honua-hosted-pilot-foundation-executor"]
    error_message = "Only the supplied reviewed policy is attached."
  }
}

run "hosted_pilot_bootstrap_requires_policy" {
  command = plan

  variables {
    hosted_pilot_bootstrap_role_enabled = true
  }

  expect_failures = [aws_iam_role.hosted_pilot_bootstrap]
}

run "hosted_pilot_bootstrap_refuses_admin_policy" {
  command = plan

  variables {
    hosted_pilot_bootstrap_role_enabled = true
    hosted_pilot_bootstrap_policy_arns  = ["arn:aws:iam::aws:policy/AdministratorAccess"]
  }

  expect_failures = [var.hosted_pilot_bootstrap_policy_arns]
}

run "hosted_pilot_bootstrap_refuses_wildcard_subject" {
  command = plan

  variables {
    hosted_pilot_bootstrap_role_enabled  = true
    hosted_pilot_bootstrap_policy_arns   = ["arn:aws:iam::123456789012:policy/honua-hosted-pilot-foundation-executor"]
    hosted_pilot_bootstrap_oidc_subjects = ["repo:honua-io/honua-iac:*"]
  }

  expect_failures = [var.hosted_pilot_bootstrap_oidc_subjects]
}

run "reuse_without_cert_permissions" {
  command = plan

  variables {
    github_repository        = "honua-demo-infra"
    github_oidc_environment  = "demo-drift"
    role_name                = "honua-demo-infra-drift-gha"
    cert_permissions_enabled = false
  }

  assert {
    condition     = aws_iam_role.github_actions.name == "honua-demo-infra-drift-gha"
    error_message = "role_name must name the federated role."
  }

  assert {
    condition     = length(aws_iam_role_policy.permissions) == 0
    error_message = "cert_permissions_enabled = false must attach no certification policy."
  }

  assert {
    condition     = tolist(local.oidc_subjects) == tolist(["repo:honua-io/honua-demo-infra:environment:demo-drift"])
    error_message = "The reused role keeps the exact environment subject."
  }
}

run "cert_permissions_stay_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.permissions) == 1 && aws_iam_role.github_actions.name == "honua-cert-cert-gha"
    error_message = "Existing consumers keep the certification policy and the historical role name."
  }
}
