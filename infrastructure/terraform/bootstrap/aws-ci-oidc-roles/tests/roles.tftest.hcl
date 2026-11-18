# Trust and permissions of the CI OIDC roles. Rendered by the real AWS
# provider with fake credentials; nothing reaches AWS.

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
  values = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/t", user_id = "AIDATEST" }
}

# for_each module instances are overridden one by one.
override_data {
  target = module.oidc["bedrock-smoke"].data.aws_caller_identity.current
  values = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/t", user_id = "AIDATEST" }
}

override_data {
  target = module.oidc["bedrock-smoke"].data.aws_region.current
  values = { name = "us-east-1", id = "us-east-1" }
}

override_data {
  target = module.oidc["bedrock-eval"].data.aws_caller_identity.current
  values = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/t", user_id = "AIDATEST" }
}

override_data {
  target = module.oidc["bedrock-eval"].data.aws_region.current
  values = { name = "us-east-1", id = "us-east-1" }
}

override_data {
  target = module.oidc["bedrock-console"].data.aws_caller_identity.current
  values = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/t", user_id = "AIDATEST" }
}

override_data {
  target = module.oidc["bedrock-console"].data.aws_region.current
  values = { name = "us-east-1", id = "us-east-1" }
}

override_data {
  target = module.oidc["inventory-plan"].data.aws_caller_identity.current
  values = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/t", user_id = "AIDATEST" }
}

override_data {
  target = module.oidc["inventory-plan"].data.aws_region.current
  values = { name = "us-east-1", id = "us-east-1" }
}

override_data {
  target = module.oidc["inventory-apply"].data.aws_caller_identity.current
  values = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/t", user_id = "AIDATEST" }
}

override_data {
  target = module.oidc["inventory-apply"].data.aws_region.current
  values = { name = "us-east-1", id = "us-east-1" }
}

variables {
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
}

run "each_role_trusts_one_exact_environment_subject" {
  command = plan

  assert {
    condition = {
      for key, role in module.oidc : key => jsondecode(role.trust_policy_json).Statement[0].Condition
      } == {
      for key, subject in {
        bedrock-smoke   = "repo:honua-io/honua-server:environment:bedrock-smoke"
        bedrock-eval    = "repo:honua-io/honua-sdk-js:environment:bedrock-eval"
        bedrock-console = "repo:honua-io/honua-console:environment:bedrock-live-llm"
        inventory-plan  = "repo:honua-io/honua-iac:environment:cell-inventory-plan"
        inventory-apply = "repo:honua-io/honua-iac:environment:cell-inventory-apply"
        } : key => {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = subject
        }
      }
    }
    error_message = "Each role must trust exactly its consumer's environment subject (no ref, pull_request or wildcard subject)."
  }

  assert {
    condition     = alltrue([for role in module.oidc : length(role.cert_policy_names) == 0])
    error_message = "No CI role may carry the certification policy."
  }
}

run "bedrock_roles_invoke_only_their_model_families" {
  command = plan

  assert {
    condition = alltrue([
      for key in ["bedrock-smoke", "bedrock-console"] :
      jsondecode(aws_iam_role_policy.grant[key].policy).Statement == [{
        Sid    = "InvokeSelectedModels"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:us-east-1::foundation-model/anthropic.*",
          "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.*",
          "arn:aws:bedrock:us-east-2::foundation-model/anthropic.*",
          "arn:aws:bedrock:us-east-2:123456789012:inference-profile/us.anthropic.*",
          "arn:aws:bedrock:us-west-1::foundation-model/anthropic.*",
          "arn:aws:bedrock:us-west-1:123456789012:inference-profile/us.anthropic.*",
          "arn:aws:bedrock:us-west-2::foundation-model/anthropic.*",
          "arn:aws:bedrock:us-west-2:123456789012:inference-profile/us.anthropic.*",
        ]
      }]
    ])
    error_message = "The server smoke and console roles may only invoke Anthropic models, directly or through the US inference profiles."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.grant["bedrock-eval"].policy).Statement == [{
      Sid    = "InvokeSelectedModels"
      Effect = "Allow"
      Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource = [
        "arn:aws:bedrock:us-east-1::foundation-model/anthropic.*",
        "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.*",
        "arn:aws:bedrock:us-east-2::foundation-model/anthropic.*",
        "arn:aws:bedrock:us-east-2:123456789012:inference-profile/us.anthropic.*",
        "arn:aws:bedrock:us-west-1::foundation-model/anthropic.*",
        "arn:aws:bedrock:us-west-1:123456789012:inference-profile/us.anthropic.*",
        "arn:aws:bedrock:us-west-2::foundation-model/anthropic.*",
        "arn:aws:bedrock:us-west-2:123456789012:inference-profile/us.anthropic.*",
        "arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-*",
        "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.amazon.nova-*",
        "arn:aws:bedrock:us-east-2::foundation-model/amazon.nova-*",
        "arn:aws:bedrock:us-east-2:123456789012:inference-profile/us.amazon.nova-*",
        "arn:aws:bedrock:us-west-1::foundation-model/amazon.nova-*",
        "arn:aws:bedrock:us-west-1:123456789012:inference-profile/us.amazon.nova-*",
        "arn:aws:bedrock:us-west-2::foundation-model/amazon.nova-*",
        "arn:aws:bedrock:us-west-2:123456789012:inference-profile/us.amazon.nova-*",
      ]
    }]
    error_message = "The sdk-js eval role may invoke the Anthropic and Amazon Nova models its workflow selects, and nothing else."
  }
}

run "inventory_roles_touch_only_the_release_role" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_role_policy.grant["inventory-plan"].policy).Statement == [{
      Sid      = "ReadReleaseRoleInlinePolicy"
      Effect   = "Allow"
      Action   = ["iam:GetRolePolicy"]
      Resource = ["arn:aws:iam::123456789012:role/honua-release-cicd"]
    }]
    error_message = "The plan role may only read the release role's inline policy."
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.grant["inventory-apply"].policy).Statement == [{
      Sid      = "ApplyReleaseRoleInlinePolicy"
      Effect   = "Allow"
      Action   = ["iam:GetRolePolicy", "iam:PutRolePolicy"]
      Resource = ["arn:aws:iam::123456789012:role/honua-release-cicd"]
    }]
    error_message = "The apply role may only read and write the release role's inline policy."
  }
}

run "reject_non_us_bedrock_region" {
  command = plan
  variables {
    bedrock_regions = ["eu-west-1"]
  }
  expect_failures = [var.bedrock_regions]
}

run "reject_foreign_oidc_provider" {
  command = plan
  variables {
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.example.com"
  }
  expect_failures = [var.oidc_provider_arn]
}
