# Trust and permission shape of the plan-only drift roles. Rendered by the
# real AWS provider with fake credentials; nothing reaches AWS.

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
  target = module.oidc["demo_infra"].data.aws_caller_identity.current
  values = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/t", user_id = "AIDATEST" }
}

override_data {
  target = module.oidc["iac_bootstrap"].data.aws_caller_identity.current
  values = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/t", user_id = "AIDATEST" }
}

override_data {
  target = module.oidc["demo_infra"].data.aws_region.current
  values = { name = "us-east-1", id = "us-east-1" }
}

override_data {
  target = module.oidc["iac_bootstrap"].data.aws_region.current
  values = { name = "us-east-1", id = "us-east-1" }
}

variables {
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  state_bucket_name = "honua-tfstate-123456789012"
}

run "trust_is_exact_environment_subjects" {
  command = plan

  assert {
    condition = jsondecode(module.oidc["demo_infra"].trust_policy_json).Statement[0].Condition == {
      StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = "repo:honua-io/honua-demo-infra:environment:demo-drift"
      }
    }
    error_message = "The demo drift role must trust only the demo-drift environment subject."
  }

  assert {
    condition = jsondecode(module.oidc["iac_bootstrap"].trust_policy_json).Statement[0].Condition == {
      StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = "repo:honua-io/honua-iac:environment:bootstrap-drift"
      }
    }
    error_message = "The bootstrap drift role must trust only the bootstrap-drift environment subject."
  }

  assert {
    condition     = alltrue([for key, mod in module.oidc : length(mod.cert_policy_names) == 0])
    error_message = "Neither drift role may carry the certification policy."
  }
}

run "allows_are_reads_plus_lock_files" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for key, doc in data.aws_iam_policy_document.plan_only : [
        for s in jsondecode(doc.json).Statement : [
          for a in flatten([try(s.Action, [])]) :
          can(regex("^[a-z0-9-]+:(Get|List|Describe|View|GET)", a)) ||
          (contains(["s3:PutObject", "s3:DeleteObject"], a) && try(s.Sid, "") == "StateLockOnly")
        ] if s.Effect == "Allow"
      ]
    ]))
    error_message = "An Allow grants a non-read action outside the lock-file statement."
  }

  assert {
    condition = alltrue([
      for key, doc in data.aws_iam_policy_document.plan_only :
      endswith(one([for s in jsondecode(doc.json).Statement : s if s.Sid == "StateLockOnly"]).Resource, ".tflock")
    ])
    error_message = "Object writes must be limited to *.tflock."
  }

  assert {
    condition = alltrue([
      for key, doc in data.aws_iam_policy_document.plan_only :
      length([for s in jsondecode(doc.json).Statement : s if try(s.Sid, "") == "DenyEverythingElse" && s.Effect == "Deny" && try(s.Resource, "") == "*"]) == 1
    ])
    error_message = "Each role needs the NotAction deny backstop."
  }

  assert {
    condition = alltrue(flatten([
      for key, doc in data.aws_iam_policy_document.plan_only : [
        for s in jsondecode(doc.json).Statement : !contains(flatten([try(s.Action, [])]), "s3:GetObject") || try(s.Resource, "") != "*" if s.Effect == "Allow"
      ]
    ]))
    error_message = "s3:GetObject must never be granted on every object."
  }
}

run "state_prefixes_are_disjoint" {
  command = plan

  assert {
    condition     = one([for s in jsondecode(data.aws_iam_policy_document.plan_only["demo_infra"].json).Statement : s if s.Sid == "StateRead"]).Resource == "arn:aws:s3:::honua-tfstate-123456789012/demo/aws-demo/*"
    error_message = "The demo role reads only the demo state prefix."
  }

  assert {
    condition     = one([for s in jsondecode(data.aws_iam_policy_document.plan_only["iac_bootstrap"].json).Statement : s if s.Sid == "StateRead"]).Resource == "arn:aws:s3:::honua-tfstate-123456789012/bootstrap/*"
    error_message = "The bootstrap role reads only the bootstrap state prefix."
  }

  assert {
    condition     = length([for s in jsondecode(data.aws_iam_policy_document.plan_only["iac_bootstrap"].json).Statement : s if s.Sid == "ManagedSecretRefresh"]) == 0
    error_message = "The bootstrap role reads no secret values."
  }

  assert {
    condition     = one([for s in jsondecode(data.aws_iam_policy_document.plan_only["demo_infra"].json).Statement : s if s.Sid == "DenyOperatorOwnedSecrets"]).Resource == "arn:aws:secretsmanager:*:123456789012:secret:honua-demo-demo/operation-key-ring*"
    error_message = "The operator-owned key ring must stay unreadable."
  }
}

run "branch_subjects_are_refused" {
  command = plan

  variables {
    demo_infra_oidc_subjects = ["repo:honua-io/honua-demo-infra:ref:refs/heads/trunk"]
  }

  expect_failures = [var.demo_infra_oidc_subjects]
}
