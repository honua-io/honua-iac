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
        "token.actions.githubusercontent.com:sub" = "repo:honua-io@217718039/honua-demo-infra@1310514636:environment:demo-drift"
      }
    }
    error_message = "The demo drift role must trust only honua-demo-infra's immutable demo-drift environment subject."
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
          (contains(["s3:PutObject", "s3:DeleteObject"], a) && try(s.Sid, "") == "StateLockOnly") ||
          (a == "kms:Decrypt" && contains(["DecryptManagedSecretsViaSecretsManager", "DecryptDemoLambdaEnvironmentViaLambda"], try(s.Sid, "")))
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
    demo_infra_oidc_subjects = ["repo:honua-io@217718039/honua-demo-infra@1310514636:ref:refs/heads/trunk"]
  }

  expect_failures = [var.demo_infra_oidc_subjects]
}

run "demo_role_reads_every_managed_secret_version" {
  command = plan

  assert {
    condition = toset(flatten([one([for s in jsondecode(data.aws_iam_policy_document.plan_only["demo_infra"].json).Statement : s if try(s.Sid, "") == "ManagedSecretRefresh"]).Resource])) == toset([
      "arn:aws:secretsmanager:us-west-2:123456789012:secret:honua-demo-demo/*",
      "arn:aws:secretsmanager:us-west-2:123456789012:secret:honua-demo/demo/*",
    ])
    error_message = "Refresh reads the module secrets and the STAC seed receipt secret; both prefixes are needed."
  }
}

run "name_form_demo_infra_subject_is_refused" {
  # honua-demo-infra tokens carry the immutable subject; a name-form subject
  # never matches (drift-plan run 40579808276), so it must not pass review.
  command = plan

  variables {
    demo_infra_oidc_subjects = ["repo:honua-io/honua-demo-infra:environment:demo-drift"]
  }

  expect_failures = [var.demo_infra_oidc_subjects]
}

run "immutable_form_iac_subject_is_refused" {
  # honua-iac tokens carry the name-form subject (use_immutable_subject = false).
  command = plan

  variables {
    iac_bootstrap_oidc_subjects = ["repo:honua-io@217718039/honua-iac@1:environment:bootstrap-drift"]
  }

  expect_failures = [var.iac_bootstrap_oidc_subjects]
}

run "demo_role_can_decrypt_only_through_its_services" {
  # Drift run 40588126748: without kms:Decrypt every secret version and every
  # Lambda environment failed to refresh.
  command = plan

  assert {
    condition     = !contains(flatten([one([for s in jsondecode(data.aws_iam_policy_document.plan_only["demo_infra"].json).Statement : s if try(s.Sid, "") == "DenyEverythingElse"]).NotAction]), "kms:Decrypt") ? false : true
    error_message = "The NotAction backstop must exempt kms:Decrypt for the demo role, or refresh cannot read secret versions or Lambda environments."
  }

  assert {
    condition = one([for s in jsondecode(data.aws_iam_policy_document.plan_only["demo_infra"].json).Statement : s if try(s.Sid, "") == "DecryptManagedSecretsViaSecretsManager"]).Condition == {
      StringEquals = { "kms:ViaService" = "secretsmanager.us-west-2.amazonaws.com" }
      StringLike = {
        "kms:EncryptionContext:SecretARN" = [
          "arn:aws:secretsmanager:us-west-2:123456789012:secret:honua-demo-demo/*",
          "arn:aws:secretsmanager:us-west-2:123456789012:secret:honua-demo/demo/*",
        ]
      }
    }
    error_message = "Secret decryption must be bound to Secrets Manager in us-west-2 and to the demo's managed secrets."
  }

  assert {
    condition = one([for s in jsondecode(data.aws_iam_policy_document.plan_only["demo_infra"].json).Statement : s if try(s.Sid, "") == "DecryptDemoLambdaEnvironmentViaLambda"]).Condition == {
      StringEquals = { "kms:ViaService" = "lambda.us-west-2.amazonaws.com" }
      StringLike   = { "kms:EncryptionContext:aws:lambda:FunctionArn" = "arn:aws:lambda:us-west-2:123456789012:function:honua-demo-demo-*" }
    }
    error_message = "Lambda environment decryption must be bound to Lambda in us-west-2 and to honua-demo-demo-* functions."
  }

  assert {
    condition = alltrue([
      for sid in ["DenyDecryptOutsideSecretsManagerAndLambda", "DenyDecryptOfOtherSecrets", "DenyDecryptOfOtherFunctionEnvironments"] :
      length([for s in jsondecode(data.aws_iam_policy_document.plan_only["demo_infra"].json).Statement : s if try(s.Sid, "") == sid && s.Effect == "Deny"]) == 1
    ])
    error_message = "The managed keys' policies allow Decrypt to every account principal via their service; explicit denies must bound it to the demo's secrets and functions."
  }

  assert {
    condition     = !contains(flatten([one([for s in jsondecode(data.aws_iam_policy_document.plan_only["iac_bootstrap"].json).Statement : s if try(s.Sid, "") == "DenyEverythingElse"]).NotAction]), "kms:Decrypt")
    error_message = "The bootstrap role reads no secrets and must keep kms:Decrypt denied."
  }
}
