locals {
  region_controls = var.shared_account ? [{
    Sid       = "DenyOtherRegions", Effect = "Deny", Resource = "*"
    NotAction = ["iam:*", "route53:*", "cloudfront:*"]
    Condition = { StringNotEquals = { "aws:RequestedRegion" = "us-east-1" } }
  }] : []

  stack_tag_controls = var.shared_account ? [{
    Sid       = "RequireGateCostTag", Effect = "Deny"
    Action    = ["cloudformation:CreateStack", "cloudformation:UpdateStack"]
    Resource  = local.stack_arn
    Condition = { StringNotEqualsIfExists = { "aws:RequestTag/HonuaGate" = "true" } }
  }] : []

  stack_tag_permissions = var.shared_account ? [{
    Sid       = "TagGateStacks", Effect = "Allow"
    Action    = "cloudformation:TagResource"
    Resource  = local.stack_arn
    Condition = { StringEquals = { "cloudformation:CreateAction" = ["CreateStack", "UpdateStack"] } }
  }] : []

  # These APIs allocate resources; they do not authorize changing an existing
  # resource merely because its name starts with honua-gate-. Unsupported
  # ownership checks fail closed, including tag-changing APIs.
  shared_creation_actions = [
    "acm:RequestCertificate", "backup:CreateBackupVault", "backup:CreateBackupPlan",
    "cognito-idp:CreateUserPool",
    "batch:CreateComputeEnvironment", "batch:CreateJobQueue", "batch:RegisterJobDefinition",
    "cloudfront:CreateDistribution", "cloudfront:CreateDistributionWithTags",
    "cloudfront:CreateOriginAccessControl", "cloudfront:CreateFunction", "cloudfront:CreateVpcOrigin",
    "ec2:AllocateAddress", "ec2:CreateVpc", "ec2:CreateSubnet", "ec2:CreateRouteTable",
    "ec2:CreateInternetGateway", "ec2:CreateNatGateway", "ec2:CreateSecurityGroup",
    "ec2:CreateVpcEndpoint", "ec2:CreateNetworkAcl", "ec2:CreateFlowLogs", "ec2:RunInstances",
    "ecs:CreateCluster", "ecs:CreateService", "ecs:RegisterTaskDefinition",
    "elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup",
    "lambda:CreateFunction", "logs:CreateLogGroup",
    "rds:CreateDBInstance", "rds:CreateDBCluster", "rds:CreateDBSubnetGroup",
    "rds:CreateDBParameterGroup", "rds:CreateDBClusterParameterGroup",
    "route53:CreateHostedZone", "secretsmanager:CreateSecret", "wafv2:CreateWebACL",
    "wafv2:CreateIPSet", "wafv2:CreateRegexPatternSet",
    "budgets:ModifyBudget", "ce:CreateAnomalyMonitor", "ce:CreateAnomalySubscription",
    "cloudtrail:CreateTrail", "cloudwatch:PutMetricAlarm", "cloudwatch:PutCompositeAlarm",
    "events:PutRule", "events:PutTargets", "guardduty:CreateDetector",
    "kms:CreateKey", "kms:CreateAlias", "sns:CreateTopic", "sqs:CreateQueue",
    "iam:CreateRole", "iam:CreateServiceLinkedRole", "iam:PassRole"
  ]
  metadata_read_actions = concat([for action in flatten([
    for service in ["acm", "application-autoscaling", "backup", "batch", "budgets", "ce", "cloudfront", "cloudtrail", "cloudwatch", "ec2", "ecs", "elasticloadbalancing", "events", "guardduty", "kms", "lambda", "logs", "rds", "route53", "secretsmanager", "sns", "sqs", "wafv2", "ecr", "iam"] : [
      "${service}:Get*", "${service}:List*", "${service}:Describe*"
    ]
    ]) : action if !contains(local.shared_content_read_actions, action)], [
    "cognito-idp:DescribeUserPool", "cognito-idp:DescribeUserPoolDomain",
    "cognito-idp:GetGroup", "cognito-idp:GetUserPoolMfaConfig", "cognito-idp:ListTagsForResource"
  ])
  # IAM and KMS reject aws:-prefixed tags, so gate roles and keys never carry
  # the CloudFormation stack-name tag. They do carry the stack's required
  # HonuaGate=true tag, which CloudFormation propagates; the deny applies only
  # when a resource has neither. Gate principals cannot add that tag to a
  # resource they do not already own.
  ownership_condition = {
    StringNotLikeIfExists   = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" }
    StringNotEqualsIfExists = { "aws:ResourceTag/HonuaGate" = "true" }
  }
  # EC2 accepts the reserved stack-name tag on post-create tagging. RDS instead
  # needs the customer request tag plus a gate name, account and region fence.
  creation_tag_actions = concat(["ec2:CreateTags", "rds:AddTagsToResource"], keys(local.named_tag_targets))
  creation_tag_deny = {
    Sid = "CreationTags", Effect = "Deny", Action = ["ec2:CreateTags"], Resource = "*"
    Condition = {
      StringNotLikeIfExists = merge(local.ownership_condition.StringNotLikeIfExists, {
        "aws:RequestTag/aws:cloudformation:stack-name" = "honua-gate-*"
      })
      StringNotEqualsIfExists = local.ownership_condition.StringNotEqualsIfExists
      Null                    = { "ec2:CreateAction" = "true" }
    }
  }
  # EC2 authorizes tag-on-create separately; the resource has no ownership tags yet.
  ec2_creation_tag_deny = {
    Sid = "EC2CreationTags", Effect = "Deny", Action = ["ec2:CreateTags"], Resource = "*"
    Condition = {
      Null                    = { "ec2:CreateAction" = "false" }
      StringNotEqualsIfExists = { "aws:RequestTag/HonuaGate" = "true" }
    }
  }
  rds_gate_arns = [for kind in ["subgrp", "db", "cluster", "pg", "og", "snapshot"] :
    "arn:aws:rds:us-east-1:${var.member_account_id}:${kind}:honua-gate-*"
  ]
  rds_creation_tag_deny = {
    Sid = "RDSCreationTags", Effect = "Deny", Action = "rds:AddTagsToResource", Resource = "*"
    Condition = merge(local.ownership_condition, {
      StringNotEqualsIfExists = merge(local.ownership_condition.StringNotEqualsIfExists, {
        "aws:RequestTag/HonuaGate" = "true"
      })
    })
  }
  rds_creation_name_deny = {
    Sid         = "RDSCreationNames", Effect = "Deny", Action = "rds:AddTagsToResource"
    NotResource = local.rds_gate_arns
  }
  # First tagging precedes ownership. Each API keeps its own name/account/region fence.
  named_tag_targets = {
    "cloudwatch:TagResource" = ["arn:aws:cloudwatch:us-east-1:${var.member_account_id}:alarm:honua-gate-*"]
    "lambda:TagResource"     = ["arn:aws:lambda:us-east-1:${var.member_account_id}:function:honua-gate-*"]
    "logs:TagResource" = [
      "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/honua/honua-gate-*",
      "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/aws/lambda/honua-gate-*",
      # AWS WAF accepts only log groups named aws-waf-logs-*; waf-logs.tf fences delivery to the same prefix.
      "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:aws-waf-logs-honua-gate-*",
      # CloudFront access logs (standard logging v2): a /aws/vendedlogs/ group named after the stack, and the
      # delivery source, destination and delivery the stack tags on create (names use the stack GUID).
      "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/aws/vendedlogs/honua/honua-gate-*",
      "arn:aws:logs:us-east-1:${var.member_account_id}:delivery-source:honua-*-edge",
      "arn:aws:logs:us-east-1:${var.member_account_id}:delivery-destination:honua-*-edge",
      "arn:aws:logs:us-east-1:${var.member_account_id}:delivery:*"
    ]
  }
  named_tag_denies = concat([{
    Sid = "NamedCreationTags", Effect = "Deny", Action = keys(local.named_tag_targets), Resource = "*"
    Condition = merge(local.ownership_condition, {
      StringNotEqualsIfExists = merge(local.ownership_condition.StringNotEqualsIfExists, {
        "aws:RequestTag/HonuaGate" = "true"
      })
    })
    }], [for action, arns in local.named_tag_targets : {
    Effect = "Deny", Action = action, NotResource = arns
  }])
  temporary_subnet_cleanup_actions = length(var.temporary_cleanup_subnet_group_names) > 0 ? ["rds:DeleteDBSubnetGroup"] : []
  temporary_subnet_cleanup_denies = length(local.temporary_subnet_cleanup_actions) > 0 ? [{
    Sid = "TemporarySubnetCleanup", Effect = "Deny", Action = "rds:DeleteDBSubnetGroup"
    NotResource = [for name in sort(tolist(var.temporary_cleanup_subnet_group_names)) :
      "arn:aws:rds:us-east-1:${var.member_account_id}:subgrp:${name}"
    ]
  }] : []
  # Exact IDs are supplied privately and removed immediately after orphan cleanup.
  network_cleanup_permissions = length(var.temporary_cleanup_vpc_ids) + length(var.temporary_cleanup_gateway_ids) > 0 ? [{
    Sid    = "TemporaryNetworkCleanup", Effect = "Allow"
    Action = ["ec2:DeleteVpc", "ec2:DeleteInternetGateway", "ec2:DetachInternetGateway"]
    Resource = concat(
      [for id in sort(tolist(var.temporary_cleanup_vpc_ids)) : "arn:aws:ec2:us-east-1:${var.member_account_id}:vpc/${id}"],
      [for id in sort(tolist(var.temporary_cleanup_gateway_ids)) : "arn:aws:ec2:us-east-1:${var.member_account_id}:internet-gateway/${id}"]
    )
  }] : []
  # CloudFront cache, origin-request and response-headers policies and origin access controls cannot carry
  # tags, their create calls take no resource and their other calls name a random ID, so neither tag nor
  # name can fence them. Only the service role (CloudFormation acting for a gate stack) may manage them;
  # workload roles keep the full fence. Functions are named, so the name fences them.
  # Route 53 health checks and CloudFront monitoring subscriptions are in the same position: their APIs take no
  # resource or a random ID and support no tag condition keys, so the edge probe and real-time metrics follow
  # the same service-role-only rule; the subscription pattern matches exactly Create, Delete and Get (the Get
  # returns only the distribution's real-time metrics setting). Hosted zones stay fenced. Risks: README.md.
  # cloudfront:Create*Policy is exactly the cache, origin-request, response-headers and (unattached until a
  # fenced UpdateDistribution) continuous-deployment policy creates; one pattern keeps the role within quota.
  # ecs:DeregisterTaskDefinition takes no resource or condition key, so stack teardown needs it here too.
  # AWS Config rules cannot carry tags from CloudFormation and their ARNs hold a random ID, so the drift rule follows
  # the same service-role-only rule; organization and aggregate rule APIs need an organization or aggregator the
  # gate account does not have (README).
  untaggable_creates  = ["cloudfront:Create*Policy", "cloudfront:*MonitoringSubscription", "route53:CreateHealthCheck", "ecs:DeregisterTaskDefinition", local.config_rule_actions]
  config_rule_actions = "config:*ConfigRule*"
  # The stack's recorder function finds the account's recorder or creates, starts and (on a failed create) removes its
  # own. Recorders and delivery channels are account singletons without tag context, so only the wildcards fence them:
  # service-linked recorders also need iam:CreateServiceLinkedRole, which the boundary never allows (README).
  workload_config_actions = ["config:*Recorder*", "config:*DeliveryChannel*"]
  untaggable_arns = concat([
    for type in ["origin-access-control", "cache-policy", "origin-request-policy", "response-headers-policy"] :
    "arn:aws:cloudfront::${var.member_account_id}:${type}/*"
    ], ["arn:aws:cloudfront::${var.member_account_id}:function/honua-gate-*", "arn:aws:route53:::healthcheck/*",
    # UpdateWebACL also authorizes against each AWS managed rule group it references, and those carry no tags;
    # the web ACL itself stays fenced by its own ownership tags. The other managedruleset actions act only on
    # rule sets this account sells as a vendor, which it does not.
  "arn:aws:wafv2:us-east-1:${var.member_account_id}:global/managedruleset/*/*"])
  service_role_unfenced = concat([aws_secretsmanager_secret.idp_client.arn], local.untaggable_arns)
  # The service role keeps account-wide metadata reads. The workload boundary
  # cannot repeat that list and stay inside the managed-policy quota, so its
  # copy exempts allocation calls, named gate buckets, Cognito domain description
  # and the lookup Lambda's four network metadata calls, which have no resource tags.
  service_role_ownership_deny = {
    Sid       = "DenyNonGateChanges", Effect = "Deny", NotResource = local.service_role_unfenced
    NotAction = concat(local.metadata_read_actions, ["s3:*", "ssm:*", "cognito-idp:TagResource", "logs:*LogDelivery", "backup-storage:MountCapsule"], local.delivery_creation_actions, local.shared_creation_actions, local.untaggable_creates, local.creation_tag_actions, local.named_teardown_actions, local.temporary_subnet_cleanup_actions)
    Condition = local.ownership_condition
  }
  # CloudFront access logs (standard logging v2). The three creates are exempt from the ownership deny because a new
  # source, destination or delivery has no tags yet; these denies fence them instead. Creates must carry the stack's
  # HonuaGate=true request tag (an existing resource must already be a gate one), a destination may only point at a
  # gate vended-log group, and a delivery may only link a gate source and destination. A resource tagged by a
  # non-gate stack cannot be retagged; an untagged foreign delivery resource stays claimable (README).
  delivery_creation_actions = ["logs:PutDeliverySource", "logs:PutDeliveryDestination", "logs:CreateDelivery"]
  delivery_denies = [{
    Sid = "DeliveryCreationTags", Effect = "Deny", Action = local.delivery_creation_actions, Resource = "*"
    Condition = merge(local.ownership_condition, {
      StringNotEqualsIfExists = merge(local.ownership_condition.StringNotEqualsIfExists, {
        "aws:RequestTag/HonuaGate" = "true"
      })
    })
    }, {
    Sid = "DeliveryDestinationTargets", Effect = "Deny", Action = "logs:PutDeliveryDestination", Resource = "*"
    Condition = { StringNotLike = {
      "logs:DeliveryDestinationResourceArn" = "arn:aws:logs:us-east-1:${var.member_account_id}:log-group:/aws/vendedlogs/honua/honua-gate-*"
    } }
    }, {
    Sid = "DeliveryLinksOwned", Effect = "Deny", Action = "logs:CreateDelivery"
    Resource = ["arn:aws:logs:us-east-1:${var.member_account_id}:delivery-source:*",
    "arn:aws:logs:us-east-1:${var.member_account_id}:delivery-destination:*"]
    Condition = local.ownership_condition
    }, {
    Sid      = "DeliveryForeignTags", Effect = "Deny", Action = "logs:TagResource"
    Resource = "arn:aws:logs:us-east-1:${var.member_account_id}:delivery*"
    Condition = {
      Null          = { "aws:ResourceTag/aws:cloudformation:stack-name" = "false" }
      StringNotLike = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" }
    }
  }]
  # Alias tags are unavailable; failed-create rules and log groups whose first tag failed may lack ownership
  # tags. Only the service role may remove these resources; name fences still reject foreign resources.
  # Log groups share the first-tag name fence, so every gate log group a stack creates stays deletable.
  named_teardown_actions = ["events:RemoveTargets", "events:DeleteRule", "kms:DeleteAlias", "logs:DeleteLogGroup", "cloudtrail:DeleteTrail"]
  named_teardown_deny = {
    Sid = "NamedTeardownFence", Effect = "Deny", Action = [for action in local.named_teardown_actions : action if action != "cloudtrail:DeleteTrail"]
    NotResource = concat([
      "arn:aws:events:us-east-1:${var.member_account_id}:rule/honua-gate-*",
      "arn:aws:kms:us-east-1:${var.member_account_id}:alias/honua-gate-*",
      "arn:aws:kms:us-east-1:${var.member_account_id}:key/*"
    ], [for arn in local.named_tag_targets["logs:TagResource"] : arn if strcontains(arn, ":log-group:")])
  }
  # A failed create rolls back a protection trail that was never created; it has no tags, so the
  # ownership deny would refuse the delete. DeleteTrail is therefore exempt from that deny and fenced here:
  # a trail tagged by a non-gate stack is refused, and outside the Launch Stack's protection-trail name
  # the usual ownership rule applies unchanged. Tagged gate trails of any name stay deletable. A hand-made untagged
  # trail with the protection name is not protected (README).
  trail_teardown_denies = [{
    Sid = "TrailTeardownFence", Effect = "Deny", Action = "cloudtrail:DeleteTrail", Resource = "*"
    Condition = {
      Null          = { "aws:ResourceTag/aws:cloudformation:stack-name" = "false" }
      StringNotLike = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" }
    }
    }, {
    Sid         = "UntaggedTrailNames", Effect = "Deny", Action = "cloudtrail:DeleteTrail"
    NotResource = "arn:aws:cloudtrail:us-east-1:${var.member_account_id}:trail/honua-protection-*"
    Condition   = local.ownership_condition
  }]
  # DeleteAlias authorizes both alias and key. Alias names supply the name fence;
  # the backing key must independently carry the gate ownership tag.
  alias_teardown_key_deny = {
    Sid       = "AliasTeardownKeys", Effect = "Deny", Action = "kms:DeleteAlias"
    Resource  = "arn:aws:kms:us-east-1:${var.member_account_id}:key/*"
    Condition = { StringNotEqualsIfExists = { "aws:ResourceTag/HonuaGate" = "true" } }
  }
  # The gate server repository is Terraform-owned, so it has no stack tag; the
  # boundary allows only pulls on ECR, and registry login (ecr:GetAuth*, exactly
  # GetAuthorizationToken) has no resource. The region wildcard saves quota; the
  # region deny already confines ECR to us-east-1.
  boundary_ownership_deny = {
    Sid = "DenyNonGateChanges", Effect = "Deny", NotResource = [aws_secretsmanager_secret.idp_client.arn, local.boundary_repository_arn, local.guardduty_agent_repository_arn]
    # The boundary allows no IAM creates, so exempting iam:CreateRole/CreateServiceLinkedRole here would grant
    # nothing; leaving them out keeps the managed policy within its 6,144-character quota.
    # guardduty:ListD* is exactly ListDetectors (the Launch Stack detector lookup), shortened for that quota.
    # ec2:DescribeM*, DescribeAv* and DescribeSu* cover the lookup Lambda's DescribeManagedPrefixLists,
    # DescribeAvailabilityZones and DescribeSubnets, shortened for the quota; they match only metadata reads,
    # none of the EC2 content reads in content-reads.tf.
    # The server finds, polls, cancels and terminates its Batch jobs. ListJobs and DescribeJobs have no resource,
    # and jobs carry only honua:stack, so all four are exempt; boundary_job_stop_deny fences the stops to gate jobs.
    # PutMetricData has no resource, so the ownership tags never match it; the operations and watchdog heartbeats
    # need it. The template's role policies fence it to their Honua/Operations and Honua/Watchdog namespaces.
    NotAction = concat(["s3:*", "ssm:*", "cognito-idp:DescribeUserPoolDomain", "cognito-idp:TagResource", "ecr:GetAuth*", "ec2:DescribeM*", "ec2:DescribeAv*", "ec2:DescribeSu*", "ec2:DescribeVpcs", "guardduty:ListD*", "batch:ListJobs", "batch:DescribeJobs", "batch:CancelJob", "batch:TerminateJob", "cloudwatch:PutMetricData"], local.workload_config_actions, [for action in local.shared_creation_actions : action if !startswith(action, "iam:Create")])
    # Secrets Manager decrypts with its AWS-managed key for callers already allowed to read the secret;
    # kms:ViaService only ever carries AWS service endpoints (secretsmanager.<region>.amazonaws.com).
    Condition = merge(local.ownership_condition, { StringNotLike = { "kms:ViaService" = "secretsmanager.*" } })
  }
  # Only metadata exceptions need a separate content deny; all other content
  # APIs are already fenced by DenyNonGateChanges. Fully denied metadata
  # families are also omitted from its exceptions to fit the inline quota.
  shared_controls = [for control in [
    {
      Sid         = "DenyOtherBuckets", Effect = "Deny", Action = "s3:*"
      NotResource = ["arn:aws:s3:::honua-gate-*", "arn:aws:s3:::honua-gate-*/*"]
    },
    {
      Sid      = "DenyState", Effect = "Deny", Action = "s3:*"
      Resource = flatten([for bucket in sort(tolist(var.protected_state_buckets)) : ["arn:aws:s3:::${bucket}", "arn:aws:s3:::${bucket}/*"]])
    },
    {
      # Only a gate stack's watchdog state and mode parameters are reachable.
      # PutParameter creates and updates in one call, so the name fences it.
      Sid         = "DenyPrivateParameters", Effect = "Deny", Action = "ssm:*"
      NotResource = local.watchdog_parameters
    },
    {
      Sid = "DenyNonGateContentReads", Effect = "Deny", NotResource = aws_secretsmanager_secret.idp_client.arn
      Action = [for action in local.shared_content_read_actions : action if anytrue([
        for pattern in local.metadata_read_actions : can(regex("^${replace(pattern, "*", ".*")}$", action))
      ])]
      Condition = { StringNotLikeIfExists = { "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*" } }
    },
    {
      # CreateUserPool requires tagging before a pool has ownership tags. Only
      # CloudFormation can supply the reserved creation tag used by this fence.
      Sid = "PoolTags", Effect = "Deny", Action = "cognito-idp:TagResource", Resource = "*"
      Condition = { StringNotLikeIfExists = {
        "aws:ResourceTag/aws:cloudformation:stack-name" = "honua-gate-*"
        "aws:RequestTag/aws:cloudformation:stack-name"  = "honua-gate-*"
      } }
    }
  ] : control if var.shared_account]
  # The ownership NotAction deny already covers every content-read action.
  # Keep the explicit content list only in the metadata-reading service policy
  # to avoid duplicating it inside the 6,144-character managed boundary.
  # The boundary allows SSM only on watchdog parameters, so it needs no
  # separate SSM deny either; that also keeps it inside the managed quota.
  # Jobs are tagged honua:stack=<stack name> at submit (the template requires it), and the boundary
  # denies batch:TagResource on every existing job, so only gate jobs can be stopped. The value matches
  # any gate stack: one gate's server can stop another gate's job if it knows the job ID.
  boundary_job_stop_deny = {
    Effect    = "Deny", Action = ["batch:CancelJob", "batch:TerminateJob"], Resource = "*"
    Condition = { StringNotLike = { "aws:ResourceTag/honua:stack" = "honua-gate-*" } }
  }
  # DenyOtherBuckets already denies every bucket outside honua-gate-*, so the boundary repeats only the
  # state buckets inside that prefix (none when the prefix is reserved, see README). One trailing wildcard
  # covers the bucket and its objects within the quota; it also denies longer bucket names, which fails closed.
  boundary_state_buckets = [for bucket in sort(tolist(var.protected_state_buckets)) : bucket if startswith(bucket, "honua-gate-")]
  boundary_state_deny = [for bucket in [local.boundary_state_buckets] : {
    Sid      = "DenyState", Effect = "Deny", Action = "s3:*"
    Resource = [for name in bucket : "arn:aws:s3:::${name}*"]
  } if length(bucket) > 0]
  boundary_shared_denies = concat([for control in local.shared_controls : control if !contains(["DenyNonGateContentReads", "DenyPrivateParameters", "DenyState"], control.Sid)], local.boundary_state_deny, local.idp_secret_controls, var.shared_account ? [local.boundary_ownership_deny] : [], var.shared_account ? [local.boundary_job_stop_deny] : [])
  # CloudFormation reads listeners, rules, ECS task definitions and Batch job definitions to create them;
  # none of these APIs accepts a resource or tag scope. Task and task-set reads stay denied.
  service_role_content_reads = ["elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeRules", "ecs:DescribeTask*", "batch:DescribeJobD*"]
  # GetDelivery* (under logs:Get*) stays a content read: it relies on the CloudFormation handlers adding the stack-name
  # tag to delivery resources. The inline policy has no room for an exemption; a gate create proves it (README).
  service_role_shared_controls = [for control in local.shared_controls : try(control.Sid, "") == "DenyNonGateContentReads" ? merge(control, {
    Action = concat([for action in control.Action : action if !contains(local.service_role_content_reads, action)], ["ecs:DescribeTasks", "ecs:DescribeTaskSets"])
  }) : control]
  service_role_shared_denies = concat(local.service_role_shared_controls, local.idp_secret_controls, var.shared_account ? [local.service_role_ownership_deny] : [])
  # PutRule, PutTargets, PutMetricAlarm, PutCompositeAlarm and ModifyBudget are
  # create and update in one API, so a missing stack tag cannot gate them.
  # Names do. The reaper schedule and shared budget match the gate prefix and
  # need their own denies.
  launch_name_denies = [
    {
      Sid    = "NameFence", Effect = "Deny"
      Action = ["events:PutRule", "events:PutTargets", "cloudwatch:PutMetricAlarm", "cloudwatch:PutCompositeAlarm", "budgets:ModifyBudget"]
      NotResource = [
        "arn:aws:events:us-east-1:${var.member_account_id}:rule/honua-gate-*",
        "arn:aws:cloudwatch:us-east-1:${var.member_account_id}:alarm:honua-gate-*",
        "arn:aws:budgets::${var.member_account_id}:budget/honua-gate-*"
      ]
    },
    {
      Sid      = "ReaperRule", Effect = "Deny", Action = "events:*"
      Resource = "arn:aws:events:us-east-1:${var.member_account_id}:rule/honua-gate-nightly-reaper"
    },
    {
      Sid      = "DenySharedBudget", Effect = "Deny", Action = "budgets:*"
      Resource = "arn:aws:budgets::${var.member_account_id}:budget/honua-gate-shared-monthly"
    }
  ]
  # CloudWatch also authorizes the CloudFormation composite-alarm create against the literal alarm:* (seen
  # live). The IAM variable $${*} matches only that asterisk. If CloudWatch evaluates PutCompositeAlarm only
  # against alarm:*, the service role can create or overwrite any composite alarm in the account (README).
  # Service role only: workloads create no composite alarms and the boundary has no room.
  service_role_launch_name_denies = [for deny in local.launch_name_denies : deny.Sid == "NameFence" ? merge(deny, {
    NotResource = concat(deny.NotResource, ["arn:aws:cloudwatch:us-east-1:${var.member_account_id}:alarm:$${*}"])
  }) : deny]
}

resource "aws_budgets_budget" "shared" {
  count        = var.shared_account ? 1 : 0
  name         = "honua-gate-shared-monthly"
  budget_type  = "COST"
  limit_amount = "300"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name   = "TagKeyValue"
    values = ["user:HonuaGate$true"]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
