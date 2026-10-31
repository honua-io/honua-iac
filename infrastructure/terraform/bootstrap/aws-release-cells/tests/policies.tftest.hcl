mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}
variables {
  oidc_provider_arn     = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  mirror_repository_arn = "arn:aws:ecr:us-east-1:123456789012:repository/honua-server"
}
run "policies" {
  command = plan
  variables {
    runtime_bedrock_model_arns = [
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-4-6",
      "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6"
    ]
    enable_workload_role_passing = true
    workload_vpc_arns            = ["arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0"]
  }
  override_data {
    target = data.aws_vpc.workload["arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0"]
    values = { tags = { Owner = "release-cell", ValidationRunId = "gha-208-aws-serverless", Environment = "test" } }
  }
  assert {
    condition     = length(local.guardrail_policy) <= 6144
    error_message = "Shared guardrails must fit the managed policy quota."
  }
  assert {
    condition     = alltrue([for policy in values(local.grant_policies) : length(policy) <= 10240])
    error_message = "The inline grant policies must fit IAM role quotas."
  }
  assert {
    condition     = length(output.runtime_boundary) <= 6144
    error_message = "The workload boundary must fit the IAM managed policy quota."
  }
  assert {
    condition     = alltrue([for lane, role in aws_iam_role.cell : jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == var.oidc_subjects[lane]])
    error_message = "Lane trust must use exact distinct OIDC subjects."
  }
  assert {
    condition = (
      contains(one([for statement in jsondecode(local.grant_policies.provision).Statement : statement if statement.Sid == "TaggedCreation"]).Action, "rds:CreateDBProxy") &&
      contains(one([for statement in jsondecode(local.grant_policies.provision).Statement : statement if statement.Sid == "PassCellRoles"]).Condition.StringEquals["iam:PassedToService"], "rds.amazonaws.com") &&
      one([for statement in jsondecode(local.grant_policies.provision).Statement : statement if statement.Sid == "CellDbProxy"]).Condition.StringEquals["aws:ResourceTag/Owner"] == "release-cell" &&
      one([for statement in jsondecode(local.grant_policies.reaper).Statement : statement if statement.Sid == "DeleteCellDbProxy"]).Condition.StringEquals["aws:ResourceTag/Owner"] == "release-cell" &&
      !contains(flatten([for statement in jsondecode(local.grant_policies.provision).Statement : statement.Action]), "rds:DeleteDBProxy")
    )
    error_message = "The provision lane must create (tagged) and wire (owned) an RDS Proxy and pass its role to rds.amazonaws.com; only the reaper lane may delete an owned proxy."
  }
}
run "reject_shared_trust" {
  command = plan
  variables {
    oidc_subjects = {
      provision = "repo:honua-io/honua-release:ref:refs/heads/trunk"
      mirror    = "repo:honua-io/honua-release:ref:refs/heads/trunk"
      reaper    = "repo:honua-io/honua-release:ref:refs/heads/trunk"
    }
  }
  expect_failures = [var.oidc_subjects]
}

run "passrole_is_disabled_before_inventory" {
  command = plan
  assert {
    condition     = alltrue([for statement in jsondecode(output.policies.provision).Statement : statement.Sid != "PassCellRoles"])
    error_message = "A fresh bootstrap must not delegate an unverified legacy role."
  }
}

run "reject_standing_network" {
  command = plan
  variables {
    workload_vpc_arns = ["arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0"]
  }
  override_data {
    target = data.aws_vpc.workload["arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0"]
    values = { tags = { Owner = "release-cell", ValidationRunId = "gha-208-aws-serverless", Environment = "cert" } }
  }
  expect_failures = [aws_iam_policy.workload_boundary]
}

run "operation_key_ring_certificate_is_admitted_exactly" {
  command = plan
  variables {
    runtime_operation_key_ring_certificate_secret_arns  = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"]
    runtime_operation_key_ring_certificate_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"]
  }
  assert {
    condition = (
      one([for s in jsondecode(output.runtime_boundary).Statement : s.Resource if s.Sid == "ReadOperationKeyRingCertificate"]) == ["arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-ABC123"] &&
      one([for s in jsondecode(output.runtime_boundary).Statement : s.Resource if s.Sid == "DecryptOperationKeyRingCertificate"]) == ["arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000002"]
    )
    error_message = "The workload boundary must admit exactly the operator's key-ring certificate secret and key."
  }
  assert {
    condition     = length(output.runtime_boundary) <= 6144
    error_message = "The workload boundary must still fit the managed policy quota."
  }
}

run "audit_chain_key_is_admitted_exactly" {
  command = plan
  variables {
    runtime_audit_chain_key_secret_arns = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"]
  }
  assert {
    condition     = one([for s in jsondecode(output.runtime_boundary).Statement : s.Resource if s.Sid == "ReadAuditChainKey"]) == ["arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-audit-chain-AbC123"]
    error_message = "The workload boundary must admit exactly the operator's audit-chain key secret."
  }
}

run "no_operation_key_ring_certificate_by_default" {
  command = plan
  assert {
    condition     = length([for s in jsondecode(output.runtime_boundary).Statement : s if contains(["ReadOperationKeyRingCertificate", "DecryptOperationKeyRingCertificate"], s.Sid)]) == 0
    error_message = "An empty certificate input must grant nothing."
  }
}

run "reject_wildcard_operation_key_ring_certificate" {
  command = plan
  variables {
    runtime_operation_key_ring_certificate_secret_arns = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:operator-keyring-*"]
  }
  expect_failures = [var.runtime_operation_key_ring_certificate_secret_arns]
}

run "latest_models_are_an_exact_boundary" {
  command = plan
  variables {
    runtime_bedrock_model_arns = [
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-opus-5-5",
      "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-opus-5-5",
      "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-opus-5-5",
      "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-opus-5-5",
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.openai.gpt-6.1-sol",
      "arn:aws:bedrock:us-east-1::foundation-model/openai.gpt-6.1-sol",
      "arn:aws:bedrock:us-east-2::foundation-model/openai.gpt-6.1-sol",
      "arn:aws:bedrock:us-west-2::foundation-model/openai.gpt-6.1-sol",
      "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.openai.gpt-6.1-terra",
      "arn:aws:bedrock:us-east-1::foundation-model/openai.gpt-6.1-terra",
      "arn:aws:bedrock:us-east-2::foundation-model/openai.gpt-6.1-terra",
      "arn:aws:bedrock:us-west-2::foundation-model/openai.gpt-6.1-terra",
    ]
  }
  assert {
    condition     = toset(one([for statement in jsondecode(output.runtime_boundary).Statement : statement if statement.Sid == "InvokeApprovedBedrockModels"]).Resource) == var.runtime_bedrock_model_arns && length(output.runtime_boundary) <= 6144
    error_message = "The workload boundary grants exactly the four latest-model ARN sets and still fits the managed policy quota."
  }
}

run "reject_wildcard_bedrock_boundary" {
  command = plan
  variables {
    runtime_bedrock_model_arns = ["arn:aws:bedrock:us-east-1::foundation-model/*"]
  }
  expect_failures = [var.runtime_bedrock_model_arns]
}

run "approver_is_a_separate_generate_mac_only_principal" {
  command = plan
  assert {
    condition = (
      jsondecode(aws_iam_role.approver.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:honua-io/honua-release:environment:terraform-live-approval" &&
      jsondecode(aws_iam_role.approver.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com" &&
      length(jsondecode(aws_iam_role.approver.assume_role_policy).Statement) == 1
    )
    error_message = "The approver must be assumable only from the protected terraform-live-approval environment."
  }
  assert {
    condition     = aws_iam_role.approver.name == "honua-release-approver" && !contains([for role in aws_iam_role.cell : role.name], aws_iam_role.approver.name)
    error_message = "The approver must be its own role, not a cell lane."
  }
  assert {
    condition = anytrue([for s in jsondecode(aws_iam_role_policy.approver.policy).Statement :
    s.Effect == "Deny" && s.NotAction == ["kms:GenerateMac"] && s.Resource == "*" && !can(s.Condition)])
    error_message = "The approver must be denied every action except kms:GenerateMac."
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.approver.policy).Statement : s.Effect == "Deny"])
    error_message = "This root grants the approver nothing; the GenerateMac Allow is scoped to the key by aws-exec-identity."
  }
  assert {
    condition = (
      aws_iam_role_policy.verifier.role == "honua-release-cell-provision" &&
      anytrue([for s in jsondecode(aws_iam_role_policy.verifier.policy).Statement : s.Effect == "Deny" && s.Action == ["kms:GenerateMac"]])
    )
    error_message = "The provision lane verifies receipts and must be denied kms:GenerateMac."
  }
  assert {
    condition     = alltrue([for lane, policy in local.grant_policies : !strcontains(policy, "kms:GenerateMac") && !strcontains(policy, "kms:VerifyMac")])
    error_message = "No cell lane grant may carry a MAC action; the verifier's VerifyMac comes only from the approval key's own policy."
  }
}

run "reject_approver_sharing_a_lane_subject" {
  command = plan
  variables {
    approver_oidc_subject = "repo:honua-io/honua-release:environment:aws-cell-provision"
  }
  expect_failures = [aws_iam_role.approver]
}

run "reject_wildcard_approver_subject" {
  command = plan
  variables {
    approver_oidc_subject = "repo:honua-io/honua-release:*"
  }
  expect_failures = [var.approver_oidc_subject]
}

run "reaper_retires_every_cell_service_it_finds" {
  command = plan
  assert {
    condition = (
      one([for s in jsondecode(local.grant_policies.reaper).Statement : s if s.Sid == "DeleteCellElastiCache"]).Condition.StringEquals["aws:ResourceTag/Owner"] == "release-cell" &&
      one([for s in jsondecode(local.grant_policies.reaper).Statement : s if s.Sid == "DeleteCellElastiCache"]).Condition.Null["aws:ResourceTag/ValidationRunId"] == "false" &&
      alltrue([for r in one([for s in jsondecode(local.grant_policies.reaper).Statement : s if s.Sid == "DeleteCellElastiCache"]).Resource :
      can(regex("^arn:aws:elasticache:us-east-1:123456789012:(replicationgroup|cluster|subnetgroup|parametergroup):(honuar|honuan|honuaeks)\\*$", r))])
    )
    error_message = "ElastiCache teardown must be limited to tagged release cells in the cell namespaces."
  }
  assert {
    condition = (
      contains(one([for s in jsondecode(local.grant_policies.reaper).Statement : s if s.Sid == "DeleteCellNetwork"]).Action, "ec2:DeleteVpcEndpoints") &&
      one([for s in jsondecode(local.grant_policies.reaper).Statement : s if s.Sid == "DeleteCellNetwork"]).Condition.StringEquals["ec2:ResourceTag/Owner"] == "release-cell"
    )
    error_message = "VPC endpoint deletion must carry the cell network's ownership condition."
  }
  assert {
    condition = alltrue([for a in ["elasticache:Describe*", "secretsmanager:DescribeSecret", "secretsmanager:ListSecrets", "batch:Describe*", "batch:List*", "rds:Describe*"] :
    contains(one([for s in jsondecode(local.grant_policies.reaper).Statement : s if s.Sid == "Discovery"]).Action, a)])
    error_message = "The reaper must be able to discover ElastiCache, Secrets Manager, Batch and RDS Proxy resources."
  }
  assert {
    condition = alltrue([for a in flatten([for s in jsondecode(local.grant_policies.reaper).Statement : s.Action]) :
    !startswith(a, "batch:") || startswith(a, "batch:Describe") || startswith(a, "batch:List")])
    error_message = "The reaper's Batch access is read-only."
  }
  assert {
    condition     = !strcontains(local.grant_policies.reaper, "secretsmanager:GetSecretValue") && !strcontains(local.grant_policies.reaper, "secretsmanager:*")
    error_message = "The reaper may describe secrets but never read their values."
  }
  assert {
    condition     = length([for s in jsondecode(local.lane_policies.reaper).Statement : s if contains(["ProtectStandingEnvironment", "ProtectStandingLifecycle", "ProtectEc2Environment", "ProtectEc2Lifecycle", "ProtectStandingNames"], s.Sid) && s.Effect == "Deny"]) == 5
    error_message = "The reaper keeps every standing/demo deny."
  }
}

run "cert_demo_zone_absent_by_default" {
  command = plan
  assert {
    condition = alltrue([for lane in ["provision", "reaper", "mirror"] :
      !strcontains(local.grant_policies[lane], "route53:") &&
      !strcontains(local.grant_policies[lane], "acm:") &&
      !strcontains(local.grant_policies[lane], "domainnames")
    ])
    error_message = "An empty cert demo zone must grant no DNS, certificate, or API Gateway domain permissions."
  }
  assert {
    condition     = length(local.cert_demo_policies) == 0
    error_message = "An empty cert demo zone must create no cert demo managed policy."
  }
}

run "cert_demo_zone_scopes_records_certificates_and_domain_names" {
  command = plan
  variables {
    cert_demo_hosted_zone_id = "Z089181827C9GKIKHXUTT"
  }
  assert {
    condition = (
      one([for statement in jsondecode(local.cert_demo_policies.provision).Statement : statement if statement.Sid == "ChangeCertDemoRecords"]).Resource == "arn:aws:route53:::hostedzone/Z089181827C9GKIKHXUTT" &&
      one([for statement in jsondecode(local.cert_demo_policies.provision).Statement : statement if statement.Sid == "ChangeCertDemoRecords"]).Condition["ForAllValues:StringLike"]["route53:ChangeResourceRecordSetsNormalizedRecordNames"] == ["*.cert.demo.honua.io"] &&
      one([for statement in jsondecode(local.cert_demo_policies.provision).Statement : statement if statement.Sid == "ChangeCertDemoRecords"]).Condition.Null["route53:ChangeResourceRecordSetsNormalizedRecordNames"] == "false" &&
      one([for statement in jsondecode(local.cert_demo_policies.reaper).Statement : statement if statement.Sid == "ChangeCertDemoRecords"]).Resource == "arn:aws:route53:::hostedzone/Z089181827C9GKIKHXUTT" &&
      !contains(keys(local.cert_demo_policies), "mirror") &&
      alltrue([for lane in ["provision", "reaper", "mirror"] : !strcontains(local.grant_policies[lane], "route53:")]) &&
      !strcontains(local.cert_demo_policies.provision, "demo.honua.io.") &&
      !can(one([for statement in jsondecode(local.cert_demo_policies.provision).Statement : statement if statement.Sid == "ChangeCertDemoRecords"]).Condition.StringEquals["aws:ResourceTag/Environment"]) &&
      contains(one([for statement in jsondecode(local.lane_policies.provision).Statement : statement if statement.Sid == "CertificationRegionOnly"]).NotAction, "route53:ChangeResourceRecordSets")
    )
    error_message = "DNS changes must be the one hosted zone and only *.cert.demo.honua.io. Route 53 is not tag-scoped, and its record API is exempt from the regional deny."
  }
  assert {
    condition = (
      contains(one([for statement in jsondecode(local.cert_demo_policies.provision).Statement : statement if statement.Sid == "RequestCellCertificate"]).Action, "acm:RequestCertificate") &&
      one([for statement in jsondecode(local.cert_demo_policies.provision).Statement : statement if statement.Sid == "RequestCellCertificate"]).Condition.StringEquals["aws:RequestTag/Owner"] == "release-cell" &&
      one([for statement in jsondecode(local.cert_demo_policies.reaper).Statement : statement if statement.Sid == "DeleteCellCertificate"]).Condition.StringEquals["aws:ResourceTag/Owner"] == "release-cell"
    )
    error_message = "Certificate grants must stay on cell request and resource tags."
  }
  assert {
    condition = (
      one([for statement in jsondecode(local.cert_demo_policies.provision).Statement : statement if statement.Sid == "CreateCellDomainName"]).Resource == "arn:aws:apigateway:us-east-1::/domainnames" &&
      contains(tolist(one([for statement in jsondecode(local.cert_demo_policies.reaper).Statement : statement if statement.Sid == "DeleteCellDomainName"]).Action), "apigateway:DELETE")
    )
    error_message = "API Gateway domain grants must be domain-name resources, not the whole API."
  }
  assert {
    condition     = alltrue([for policy in values(local.cert_demo_policies) : length(policy) <= 6144])
    error_message = "Each cert demo managed policy must fit the 6,144-byte managed policy quota."
  }
  assert {
    condition = alltrue([for lane in ["provision", "reaper", "mirror"] :
      length([for statement in jsondecode(local.grant_policies[lane]).Statement : statement if contains(local.cert_demo_sids, statement.Sid)]) == 0 &&
      length(local.grant_policies[lane]) <= 9216
    ])
    error_message = "Cert demo statements must stay out of the inline grant, which needs headroom under IAM's 10,240-byte aggregate inline quota (the provision role also holds the approval verifier). Lengths: ${length(local.grant_policies.provision)} ${length(local.grant_policies.reaper)} ${length(local.grant_policies.mirror)}."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.cert_demo["provision"].role == "honua-release-cell-provision" && aws_iam_role_policy_attachment.cert_demo["reaper"].role == "honua-release-cell-reaper"
    error_message = "The cert demo managed policies attach to the provision and reaper roles only."
  }
}

run "reject_wildcard_cert_demo_zone" {
  command = plan
  variables {
    cert_demo_hosted_zone_id = "Z*"
  }
  expect_failures = [var.cert_demo_hosted_zone_id]
}

run "only_the_reaper_lane_gets_a_two_hour_session" {
  command = plan
  assert {
    condition = (
      aws_iam_role.cell["reaper"].max_session_duration == 7200 &&
      aws_iam_role.cell["provision"].max_session_duration == 3600 &&
      aws_iam_role.cell["mirror"].max_session_duration == 3600
    )
    error_message = "The reaper lane must accept the sweep's 7200 s session; provision and mirror stay at one hour."
  }
}
