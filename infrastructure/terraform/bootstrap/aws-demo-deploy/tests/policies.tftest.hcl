# Trust and guardrails of the demo apply role. Rendered by the
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
  target = module.oidc.data.aws_caller_identity.current
  values = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/t", user_id = "AIDATEST" }
}

override_data {
  target = module.oidc.data.aws_region.current
  values = { name = "us-east-1", id = "us-east-1" }
}

override_data {
  target = data.aws_route53_zone.demo
  values = { arn = "arn:aws:route53:::hostedzone/Z0123456789ABCDEFGHIJ", zone_id = "Z0123456789ABCDEFGHIJ", name = "demo.honua.io" }
}

variables {
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  state_bucket_name = "honua-tfstate-123456789012"
}

run "trust_is_the_protected_demo_environment_only" {
  command = plan

  assert {
    condition = jsondecode(module.oidc.trust_policy_json).Statement[0].Condition == {
      StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = "repo:honua-io/honua-demo-infra:environment:demo"
      }
    }
    error_message = "The apply role must trust only the demo environment subject."
  }

  assert {
    condition     = length(module.oidc.cert_policy_names) == 0
    error_message = "The apply role must not carry the certification policy."
  }
}

run "guardrail_denies_are_present" {
  command = plan

  assert {
    condition = alltrue([
      for sid in ["DenyOtherRegions", "DenyDataDestruction", "DenyIdentityEscalation", "DenyIamWritesOutsideTheDemo", "DenyGhaRoles", "DenyOtherObjects", "DenyOperatorOwnedSecrets"] :
      length([for s in jsondecode(data.aws_iam_policy_document.apply.json).Statement : s if try(s.Sid, "") == sid && s.Effect == "Deny"]) == 1
    ])
    error_message = "Every guardrail deny must be present."
  }

  assert {
    condition = toset(flatten([one([for s in jsondecode(data.aws_iam_policy_document.apply.json).Statement : s if try(s.Sid, "") == "DenyDataDestruction"]).Action])) == toset([
      "rds:DeleteDBInstance", "rds:DeleteDBCluster", "rds:DeleteDBSnapshot", "s3:DeleteBucket",
      "secretsmanager:DeleteSecret", "ec2:DeleteVpc", "route53:DeleteHostedZone",
    ])
    error_message = "The apply role must never delete the database, the data bucket, a secret, the VPC or the zone."
  }

  assert {
    condition     = contains(flatten([one([for s in jsondecode(data.aws_iam_policy_document.apply.json).Statement : s if try(s.Sid, "") == "DenyIdentityEscalation"]).Action]), "sts:AssumeRole")
    error_message = "Role chaining must be denied."
  }
}

run "iam_writes_stay_on_demo_names" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for s in jsondecode(data.aws_iam_policy_document.apply.json).Statement : [
        for r in flatten([try(s.Resource, [])]) : can(regex("^arn:aws:iam::123456789012:(role|policy)/honua-demo-demo-\\*$", r))
      ] if s.Effect == "Allow" && anytrue([for a in flatten([try(s.Action, [])]) : can(regex("^iam:(Create|Delete|Put|Update|Attach|Detach|Tag|Untag|Pass|Set)", a))])
    ]))
    error_message = "Every IAM write must be scoped to honua-demo-demo-* roles or policies."
  }

  assert {
    condition     = one([for s in jsondecode(data.aws_iam_policy_document.apply.json).Statement : s if try(s.Sid, "") == "DemoRolesAttachOnlyKnownPolicies"]).Condition.ArnLike["iam:PolicyARN"] != null
    error_message = "AttachRolePolicy must be limited to the Lambda service policies and the demo's own policies."
  }

  assert {
    condition     = one([for s in jsondecode(data.aws_iam_policy_document.apply.json).Statement : s if try(s.Sid, "") == "DemoZoneRecords"]).Resource == "arn:aws:route53:::hostedzone/Z0123456789ABCDEFGHIJ"
    error_message = "Record changes are limited to the demo zone."
  }
}

run "pull_request_subjects_are_refused" {
  command = plan

  variables {
    oidc_subjects = ["repo:honua-io/honua-demo-infra:pull_request"]
  }

  expect_failures = [var.oidc_subjects]
}
