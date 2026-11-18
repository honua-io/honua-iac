# Trust and permissions of the honua-server ECR publish role. Rendered by the
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
  values = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/t", user_id = "AIDATEST" }
}

override_data {
  target = module.oidc.data.aws_caller_identity.current
  values = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/t", user_id = "AIDATEST" }
}

override_data {
  target = module.oidc.data.aws_region.current
  values = { name = "us-east-1", id = "us-east-1" }
}

variables {
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
}

run "trust_is_the_publish_images_environment_only" {
  command = plan

  assert {
    condition = jsondecode(module.oidc.trust_policy_json).Statement[0].Condition == {
      StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = "repo:honua-io/honua-server:environment:publish-images"
      }
    }
    error_message = "Only honua-server jobs in the publish-images environment (trunk, release/* and publication tags) may assume the role."
  }

  assert {
    condition     = module.oidc.role_name == "honua-server-gha-ecr-publish" && length(module.oidc.cert_policy_names) == 0
    error_message = "Keep the role name the workflows assume, without the certification policy."
  }
}

run "permissions_are_push_to_the_publication_repository_only" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_role_policy.publish.policy).Statement == [
      {
        Sid      = "RegistryLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PublishRepository"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:CreateRepository",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:ListImages",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = ["arn:aws:ecr:us-west-2:123456789012:repository/honua-server"]
      },
    ]
    error_message = "The role may log in and push only to the honua-server repository in the publication region."
  }

  assert {
    condition     = aws_iam_role_policies_exclusive.publish.policy_names == toset(["ecr-publish"]) && length(aws_iam_role_policy_attachments_exclusive.publish.policy_arns) == 0
    error_message = "Inline and managed policies added outside Terraform must be removed on apply."
  }
}

run "reject_branch_subject" {
  command = plan
  variables {
    oidc_subjects = ["repo:honua-io/honua-server:ref:refs/heads/feature"]
  }
  expect_failures = [var.oidc_subjects]
}

run "reject_other_repository" {
  command = plan
  variables {
    oidc_subjects = ["repo:honua-io/honua-sdk-js:environment:publish-images"]
  }
  expect_failures = [var.oidc_subjects]
}

run "reject_pull_request_subject" {
  command = plan
  variables {
    oidc_subjects = ["repo:honua-io/honua-server:pull_request"]
  }
  expect_failures = [var.oidc_subjects]
}
