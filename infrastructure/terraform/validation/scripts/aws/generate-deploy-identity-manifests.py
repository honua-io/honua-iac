#!/usr/bin/env python3
"""Build and check topology deploy-identity action manifests.

The manifests are the allow-list bootstrap/aws-exec-identity assembles. Service
actions are derived from the bootstrap templates and the explicit provider
resource lifecycle inventories below, split into one file per module and one
file per optional feature. A resource type the module (or a registry
module it calls) declares must map to at least one IAM action in the manifest
that owns it. terraform providers schema confirms the type is a real AWS
provider resource.

  python3 generate-deploy-identity-manifests.py --write
  python3 generate-deploy-identity-manifests.py --check

--check exits non-zero when an action contains a wildcard, a resource type has
no actions, a type is not in the provider schema, or files differ from output.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[5]
TF = REPO / "infrastructure" / "terraform"
BOOTSTRAP = TF / "bootstrap"
MODULES = TF / "modules"
MANIFEST_DIR = BOOTSTRAP / "aws-exec-identity" / "manifests"
EXEC_ROOT = BOOTSTRAP / "aws-exec-identity"

FEATURE_SERVICES = {
    "redis": {"elasticache"},
    "custom-domain": {"acm", "route53"},
    "waf": {"wafv2"},
    "gp-batch": {"batch"},
}

# Provider lifecycle and tag calls for these feature resources. See:
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_elasticache.html
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_batch.html
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_replication_group
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_subnet_group
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/batch_compute_environment
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/batch_job_queue
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/batch_job_definition
FEATURE_EXACT_ACTIONS = {
    "redis": [
        "elasticache:AddTagsToResource", "elasticache:RemoveTagsFromResource",
        "elasticache:ListTagsForResource", "elasticache:CreateCacheSubnetGroup",
        "elasticache:DeleteCacheSubnetGroup", "elasticache:DescribeCacheSubnetGroups",
        "elasticache:ModifyCacheSubnetGroup", "elasticache:CreateReplicationGroup",
        "elasticache:DeleteReplicationGroup", "elasticache:DescribeReplicationGroups",
        "elasticache:DescribeCacheClusters", "elasticache:ModifyReplicationGroup",
        "elasticache:ModifyReplicationGroupShardConfiguration",
        "elasticache:IncreaseReplicaCount", "elasticache:DecreaseReplicaCount",
        "elasticache:DisassociateGlobalReplicationGroup",
    ],
    "gp-batch": [
        "batch:CreateComputeEnvironment", "batch:DeleteComputeEnvironment",
        "batch:DescribeComputeEnvironments", "batch:UpdateComputeEnvironment",
        "batch:CreateJobQueue", "batch:DeleteJobQueue", "batch:DescribeJobQueues",
        "batch:UpdateJobQueue", "batch:RegisterJobDefinition",
        "batch:DeregisterJobDefinition", "batch:DescribeJobDefinitions",
        "batch:ListTagsForResource", "batch:TagResource", "batch:UntagResource",
    ],
    # The ECS module associates an operator-provided ACL; it does not create it.
    # https://docs.aws.amazon.com/service-authorization/latest/reference/list_wafv2.html
    "waf": [
        "wafv2:AssociateWebACL", "wafv2:DisassociateWebACL", "wafv2:GetWebACLForResource",
        "elasticloadbalancing:CreateWebACLAssociation", "elasticloadbalancing:DeleteWebACLAssociation",
        "elasticloadbalancing:GetLoadBalancerWebACL", "elasticloadbalancing:SetWebAcl",
    ],
}

# Resource lifecycle operations from the provider implementation and the
# corresponding AWS service authorization references:
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecs.html
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_eks.html
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_lambda.html
COMPUTE_EXACT_ACTIONS = {
    "ecs": [
        "CreateCluster", "DeleteCluster", "DescribeClusters", "UpdateCluster",
        "CreateService", "DeleteService", "DescribeServices", "UpdateService",
        "DescribeServiceDeployments", "ListServiceDeployments", "ListServices", "StopServiceDeployment",
        "RegisterTaskDefinition", "DeregisterTaskDefinition", "DescribeTaskDefinition",
        "ListTagsForResource", "TagResource", "UntagResource",
    ],
    "eks": [
        "CreateAccessEntry", "DeleteAccessEntry", "DescribeAccessEntry", "UpdateAccessEntry",
        "AssociateAccessPolicy", "DisassociateAccessPolicy", "ListAssociatedAccessPolicies",
        "CreateAddon", "DeleteAddon", "DescribeAddon", "UpdateAddon", "DescribeUpdate",
        "DescribeAddonVersions",
        "AssociateEncryptionConfig", "CreateCluster", "DeleteCluster", "DescribeCluster",
        "UpdateClusterConfig", "UpdateClusterVersion", "CreateFargateProfile",
        "DeleteFargateProfile", "DescribeFargateProfile", "AssociateIdentityProviderConfig",
        "DescribeIdentityProviderConfig", "DisassociateIdentityProviderConfig", "CreateNodegroup",
        "DeleteNodegroup", "DescribeNodegroup", "UpdateNodegroupConfig", "UpdateNodegroupVersion",
        "CreatePodIdentityAssociation", "DeletePodIdentityAssociation", "DescribePodIdentityAssociation",
        "UpdatePodIdentityAssociation", "ListTagsForResource", "TagResource", "UntagResource",
    ],
    "lambda": [
        "CreateAlias", "DeleteAlias", "GetAlias", "UpdateAlias", "CreateFunction",
        "DeleteFunction", "GetFunction", "GetFunctionConfiguration", "UpdateFunctionCode",
        "UpdateFunctionConfiguration", "DeleteFunctionCodeSigningConfig", "GetFunctionCodeSigningConfig",
        "PutFunctionCodeSigningConfig", "DeleteFunctionConcurrency", "GetFunctionConcurrency",
        "PutFunctionConcurrency", "ListVersionsByFunction", "PublishVersion", "InvokeFunction",
        "GetDurableExecution", "ListDurableExecutionsByFunction", "StopDurableExecution",
        "AddPermission", "GetPolicy", "RemovePermission", "TagResource", "UntagResource", "ListTags",
    ],
}

# The provider reads scalable targets and policies by their identifiers.
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_application-autoscaling.html
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_target
PATTERN_REPLACEMENTS = {
    "application-autoscaling:Describe*": [
        "application-autoscaling:DescribeScalableTargets",
        "application-autoscaling:DescribeScalingPolicies",
    ],
    # AWS Logs: https://docs.aws.amazon.com/service-authorization/latest/reference/list_logs.html
    "logs:Create*": ["logs:CreateLogGroup"],
    "logs:Delete*": ["logs:DeleteLogGroup", "logs:DeleteRetentionPolicy"],
    "logs:Describe*": ["logs:DescribeLogGroups", "logs:DescribeMetricFilters", "logs:DescribeResourcePolicies"],
    # EKS node-group AMI lookups use aws_ssm_parameter, which calls GetParameter.
    # https://docs.aws.amazon.com/service-authorization/latest/reference/list_ssm.html
    "ssm:Create*": [],
    "ssm:Delete*": [],
    "ssm:Describe*": [],
    "ssm:Get*": ["ssm:GetParameter"],
    "ssm:List*": [],
    "ssm:Put*": [],
    "ssm:Update*": [],
    # https://docs.aws.amazon.com/service-authorization/latest/reference/list_cloudwatch.html
    "cloudwatch:Describe*": ["cloudwatch:DescribeAlarms"],
    "cloudwatch:Get*": ["cloudwatch:GetDashboard"],
    "cloudwatch:List*": [],
    "cloudwatch:Put*": ["cloudwatch:PutDashboard", "cloudwatch:PutMetricAlarm"],
    # https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecr.html
    "ecr:Describe*": ["ecr:DescribeRepositories"],
    "ecr:List*": [],
    # https://docs.aws.amazon.com/service-authorization/latest/reference/list_kms.html
    "kms:Describe*": ["kms:DescribeKey"],
    "kms:GenerateDataKey*": ["kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext"],
    # https://docs.aws.amazon.com/service-authorization/latest/reference/list_elbv2.html
    "elasticloadbalancing:Create*": [
        "elasticloadbalancing:CreateListener", "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:CreateRule", "elasticloadbalancing:CreateTargetGroup",
    ],
    "elasticloadbalancing:Delete*": [
        "elasticloadbalancing:DeleteListener", "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:DeleteRule", "elasticloadbalancing:DeleteTargetGroup",
    ],
    "elasticloadbalancing:Describe*": [
        "elasticloadbalancing:DescribeCapacityReservation", "elasticloadbalancing:DescribeListenerAttributes",
        "elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeLoadBalancerAttributes",
        "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeRules",
        "elasticloadbalancing:DescribeTags", "elasticloadbalancing:DescribeTargetGroupAttributes",
        "elasticloadbalancing:DescribeTargetGroups",
    ],
    "elasticloadbalancing:Modify*": [
        "elasticloadbalancing:ModifyCapacityReservation", "elasticloadbalancing:ModifyIpPools",
        "elasticloadbalancing:ModifyListener", "elasticloadbalancing:ModifyListenerAttributes",
        "elasticloadbalancing:ModifyLoadBalancerAttributes", "elasticloadbalancing:ModifyRule",
        "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes",
    ],
    "elasticloadbalancing:Set*": [
        "elasticloadbalancing:SetIpAddressType", "elasticloadbalancing:SetRulePriorities",
        "elasticloadbalancing:SetSecurityGroups", "elasticloadbalancing:SetSubnets",
    ],
}
GLOBAL_SERVICES = {"route53"}

# Network operations are shared by the VPC and security group resources in all
# three modules and their registry VPC module. See AWS provider resource docs
# and https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html.
EC2_VPC_ACTIONS = {
    "CreateCustomerGateway", "CreateDefaultVpc", "CreateDhcpOptions",
    "CreateEgressOnlyInternetGateway", "CreateFlowLogs", "CreateInternetGateway",
    "CreateNatGateway", "CreateNetworkAcl", "CreateNetworkAclEntry", "CreateRoute",
    "CreateRouteTable", "CreateSecurityGroup", "CreateSubnet", "CreateVpc",
    "CreateVpcBlockPublicAccessExclusion", "CreateVpcEndpoint", "CreateVpnGateway",
    "DeleteCustomerGateway", "DeleteDhcpOptions", "DeleteEgressOnlyInternetGateway",
    "DeleteFlowLogs", "DeleteInternetGateway", "DeleteNatGateway", "DeleteNetworkAcl",
    "DeleteNetworkAclEntry", "DeleteRoute", "DeleteRouteTable", "DeleteSecurityGroup",
    "DeleteSubnet", "DeleteVpc", "DeleteVpcBlockPublicAccessExclusion",
    "DeleteVpcEndpoints", "DeleteVpnGateway", "DeleteTags", "CreateTags",
    "DescribeAddresses", "DescribeAddressesAttribute", "DescribeAvailabilityZones", "DescribeCustomerGateways",
    "DescribeDhcpOptions", "DescribeEgressOnlyInternetGateways", "DescribeFlowLogs",
    "DescribeInternetGateways", "DescribeNatGateways", "DescribeNetworkAcls", "DescribeNetworkInterfaces",
    "DescribePrefixLists", "DescribeVpcEndpointServiceConfigurations",
    "DescribeRouteTables", "DescribeSecurityGroupRules", "DescribeSecurityGroups",
    "DescribeSubnets", "DescribeVpcAttribute", "DescribeVpcBlockPublicAccessExclusions",
    "DescribeVpcBlockPublicAccessOptions", "DescribeVpcEndpoints", "DescribeVpcEndpointServices", "DescribeVpcs",
    "DescribeVpnGateways", "ModifySubnetAttribute", "ModifyVpcAttribute",
    "ModifyVpcBlockPublicAccessExclusion", "ModifyVpcBlockPublicAccessOptions",
    "ModifyVpcEndpoint", "ModifyVpcTenancy",
}
EC2_EKS_ACTIONS = {
    "CreateLaunchTemplate", "CreateLaunchTemplateVersion", "DeleteLaunchTemplate",
    "ModifyLaunchTemplate", "DescribeLaunchTemplates", "DescribeLaunchTemplateVersions",
    "CreatePlacementGroup", "DeletePlacementGroup", "DescribePlacementGroups",
    "DescribeInstanceTypes", "DescribeInstanceTypeOfferings",
}
EC2_VPC_ADDITIONAL_ACTIONS = {
    "AcceptVpcEndpointConnections", "AllocateAddress", "AssociateAddress", "AssociateDhcpOptions",
    "AssociateNatGatewayAddress", "AssociateRouteTable", "AssociateSubnetCidrBlock",
    "AssociateVpcCidrBlock", "AssignPrivateNatGatewayAddress", "AttachInternetGateway",
    "AttachVpnGateway", "AuthorizeSecurityGroupEgress", "AuthorizeSecurityGroupIngress",
    "DetachInternetGateway", "DetachVpnGateway", "DisableVgwRoutePropagation",
    "DisassociateAddress", "DisassociateNatGatewayAddress", "DisassociateRouteTable",
    "DisassociateSubnetCidrBlock", "DisassociateVpcCidrBlock", "EnableVgwRoutePropagation",
    "ReleaseAddress", "ReplaceRoute", "ReplaceRouteTableAssociation",
    "RevokeSecurityGroupEgress", "RevokeSecurityGroupIngress", "UnassignPrivateNatGatewayAddress",
    "UpdateSecurityGroupRuleDescriptionsEgress", "UpdateSecurityGroupRuleDescriptionsIngress",
}

# https://docs.aws.amazon.com/service-authorization/latest/reference/list_rds.html
# AWS provider resources: db_instance, db_instance_automated_backups_replication,
# db_instance_role_association, db_option_group, db_parameter_group and
# db_subnet_group; the serverless module additionally declares a DB proxy.
RDS_COMMON_ACTIONS = {
    "AddRoleToDBInstance", "RemoveRoleFromDBInstance", "CreateDBInstance",
    "CreateDBInstanceReadReplica", "DeleteDBInstance", "DescribeDBInstances",
    "ModifyDBInstance", "PromoteReadReplica", "RebootDBInstance", "StartDBInstance",
    "StopDBInstance", "RestoreDBInstanceFromDBSnapshot", "RestoreDBInstanceFromS3",
    "RestoreDBInstanceToPointInTime", "DeleteBlueGreenDeployment", "DescribeBlueGreenDeployments",
    "DescribeDBInstanceAutomatedBackups", "StartDBInstanceAutomatedBackupsReplication",
    "StopDBInstanceAutomatedBackupsReplication", "CreateOptionGroup", "DeleteOptionGroup",
    "DescribeOptionGroups", "ModifyOptionGroup", "CreateDBParameterGroup", "DeleteDBParameterGroup",
    "DescribeDBParameterGroups", "DescribeDBParameters", "ModifyDBParameterGroup",
    "ResetDBParameterGroup", "CreateDBSubnetGroup", "DeleteDBSubnetGroup",
    "DescribeDBSubnetGroups", "ModifyDBSubnetGroup", "AddTagsToResource",
    "ListTagsForResource", "RemoveTagsFromResource",
}
RDS_PROXY_ACTIONS = {
    "CreateDBProxy", "DeleteDBProxy", "DescribeDBProxies", "ModifyDBProxy",
    "DescribeDBProxyTargetGroups", "ModifyDBProxyTargetGroup", "DeregisterDBProxyTargets",
    "DescribeDBProxyTargets", "RegisterDBProxyTargets",
}
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_autoscaling.html
# The EKS registry module can declare an autoscaling group and a schedule.
AUTOSCALING_ACTIONS = {
    "AttachLoadBalancerTargetGroups", "AttachLoadBalancers", "AttachTrafficSources",
    "CancelInstanceRefresh", "CreateAutoScalingGroup", "DeleteAutoScalingGroup", "DeleteWarmPool",
    "DescribeAutoScalingGroups", "DescribeInstanceRefreshes", "DescribeLoadBalancerTargetGroups",
    "DescribeLoadBalancers", "DescribeScalingActivities", "DescribeTrafficSources", "DescribeWarmPool",
    "DetachLoadBalancerTargetGroups", "DetachLoadBalancers", "DetachTrafficSources",
    "DisableMetricsCollection", "EnableMetricsCollection", "PutLifecycleHook", "PutWarmPool",
    "ResumeProcesses", "SetInstanceProtection", "StartInstanceRefresh", "SuspendProcesses",
    "UpdateAutoScalingGroup", "DeleteScheduledAction", "DescribeScheduledActions",
    "PutScheduledUpdateGroupAction", "CreateOrUpdateTags", "DeleteTags", "DescribeTags",
}
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_s3.html
# Bucket API operations sometimes authorize a differently named IAM action:
# HeadBucket uses ListBucket, and encryption/lifecycle calls use the actions below.
S3_BUCKET_ACTIONS = {
    "CreateBucket", "DeleteBucket", "ListBucket", "GetBucketLocation", "GetBucketAcl",
    "GetBucketCORS", "GetBucketWebsite", "GetBucketVersioning", "GetAccelerateConfiguration",
    "GetBucketRequestPayment", "GetBucketLogging", "GetLifecycleConfiguration",
    "GetReplicationConfiguration", "GetEncryptionConfiguration", "GetBucketObjectLockConfiguration",
    "GetBucketPolicy", "GetBucketOwnershipControls", "GetBucketPublicAccessBlock", "GetBucketTagging",
    "PutBucketAcl", "PutBucketCORS", "PutBucketWebsite", "PutBucketVersioning",
    "PutAccelerateConfiguration", "PutBucketRequestPayment", "PutBucketLogging",
    "PutLifecycleConfiguration", "PutReplicationConfiguration", "PutEncryptionConfiguration",
    "PutBucketObjectLockConfiguration", "PutBucketPolicy", "DeleteBucketPolicy",
    "PutBucketOwnershipControls", "PutBucketPublicAccessBlock", "PutBucketTagging",
}


# Longest prefix wins. The service is the IAM prefix, which is what "has
# actions" means for a resource type.
PREFIX_SERVICE = sorted(
    [
        ("aws_appautoscaling_", "application-autoscaling"),
        ("aws_apigatewayv2_", "apigateway"),
        ("aws_elasticache_", "elasticache"),
        ("aws_lb_", "elasticloadbalancing"),
        ("aws_lb", "elasticloadbalancing"),
        ("aws_ecs_", "ecs"),
        ("aws_eks_", "eks"),
        ("aws_lambda_", "lambda"),
        ("aws_batch_", "batch"),
        ("aws_db_", "rds"),
        ("aws_rds_", "rds"),
        ("aws_cloudwatch_log_metric_filter", "logs"),
        ("aws_cloudwatch_log_", "logs"),
        ("aws_cloudwatch_event_", "events"),
        ("aws_cloudwatch_", "cloudwatch"),
        ("aws_scheduler_", "scheduler"),
        ("aws_sns_", "sns"),
        ("aws_secretsmanager_", "secretsmanager"),
        ("aws_kms_", "kms"),
        ("aws_s3_", "s3"),
        ("aws_ecr_", "ecr"),
        ("aws_acm_", "acm"),
        ("aws_route53_", "route53"),
        ("aws_wafv2_", "wafv2"),
        ("aws_iam_", "iam"),
        ("aws_codeartifact_", "codeartifact"),
        ("aws_location_", "geo"),
        ("aws_vpc_", "ec2"),
        ("aws_vpc", "ec2"),
        ("aws_subnet", "ec2"),
        ("aws_security_group", "ec2"),
        ("aws_nat_gateway", "ec2"),
        ("aws_internet_gateway", "ec2"),
        ("aws_egress_only_internet_gateway", "ec2"),
        ("aws_customer_gateway", "ec2"),
        ("aws_vpn_gateway", "ec2"),
        ("aws_eip", "ec2"),
        ("aws_ec2_", "ec2"),
        ("aws_route", "ec2"),
        ("aws_network_acl", "ec2"),
        ("aws_default_", "ec2"),
        ("aws_flow_log", "ec2"),
        ("aws_launch_template", "ec2"),
        ("aws_autoscaling_", "autoscaling"),
        ("aws_ssm_", "ssm"),
        ("aws_redshift_", "redshift"),
        ("aws_sqs_", "sqs"),
        ("aws_rolesanywhere_", "rolesanywhere"),
        ("aws_placement_group", "ec2"),
        ("aws_key_pair", "ec2"),
        ("aws_ebs_", "ec2"),
        ("aws_volume_", "ec2"),
        ("aws_instance", "ec2"),
    ],
    key=lambda item: len(item[0]),
    reverse=True,
)

# Additional lifecycle actions for resource types. The generator adds them to
# the manifest that owns the resource type.
EXACT_ACTIONS = {
    "aws_acm_certificate": ["acm:UpdateCertificateOptions"],
    "aws_cloudwatch_log_group": [
        "logs:AssociateKmsKey", "logs:DisassociateKmsKey", "logs:ListTagsForResource",
        "logs:PutLogGroupDeletionProtection", "logs:TagResource", "logs:UntagResource",
    ],
    "aws_cloudwatch_metric_alarm": [
        "cloudwatch:ListTagsForResource", "cloudwatch:TagResource", "cloudwatch:UntagResource",
    ],
    "aws_eip": ["ec2:GetIpamPoolAllocations"],
    "aws_vpc": ["ec2:GetIpamPoolAllocations"],
    "aws_ecr_repository": ["ecr:ListTagsForResource", "ecr:PutImageTagMutability"],
    "aws_kms_alias": ["kms:UpdateAlias"],
    "aws_kms_key": ["kms:DisableKey", "kms:DisableKeyRotation", "kms:EnableKey", "kms:UpdateKeyDescription"],
    "aws_kms_external_key": ["kms:GetParametersForImport", "kms:ImportKeyMaterial"],
    "aws_kms_grant": ["kms:CreateGrant", "kms:ListGrants", "kms:RetireGrant", "kms:RevokeGrant"],
    "aws_kms_replica_external_key": ["kms:ReplicateKey"],
    "aws_kms_replica_key": ["kms:ReplicateKey"],
    "aws_secretsmanager_secret": [
        "secretsmanager:DeleteResourcePolicy", "secretsmanager:PutResourcePolicy",
        "secretsmanager:RemoveRegionsFromReplication", "secretsmanager:ReplicateSecretToRegions",
    ],
    "aws_secretsmanager_secret_rotation": ["secretsmanager:CancelRotateSecret", "secretsmanager:RotateSecret"],
    "aws_secretsmanager_secret_version": ["secretsmanager:ListSecretVersionIds", "secretsmanager:UpdateSecretVersionStage"],
    "aws_cloudwatch_log_metric_filter": [
        "logs:DeleteMetricFilter",
        "logs:DescribeMetricFilters",
        "logs:PutMetricFilter",
    ],
    "aws_lambda_function_event_invoke_config": [
        "lambda:DeleteFunctionEventInvokeConfig",
        "lambda:GetFunctionEventInvokeConfig",
        "lambda:PutFunctionEventInvokeConfig",
    ],
    "aws_cloudwatch_event_rule": [
        "events:DeleteRule",
        "events:DescribeRule",
        "events:ListTagsForResource",
        "events:PutRule",
        "events:TagResource",
        "events:UntagResource",
    ],
    "aws_cloudwatch_event_target": [
        "events:ListTargetsByRule",
        "events:PutTargets",
        "events:RemoveTargets",
    ],
    "aws_scheduler_schedule": [
        "scheduler:CreateSchedule",
        "scheduler:DeleteSchedule",
        "scheduler:GetSchedule",
        "scheduler:ListTagsForResource",
        "scheduler:TagResource",
        "scheduler:UntagResource",
        "scheduler:UpdateSchedule",
    ],
    "aws_scheduler_schedule_group": [
        "scheduler:CreateScheduleGroup",
        "scheduler:DeleteScheduleGroup",
        "scheduler:GetScheduleGroup",
        "scheduler:ListTagsForResource",
        "scheduler:TagResource",
        "scheduler:UntagResource",
    ],
    "aws_sns_topic": [
        "sns:CreateTopic",
        "sns:DeleteTopic",
        "sns:GetTopicAttributes",
        "sns:ListTagsForResource",
        "sns:SetTopicAttributes",
        "sns:TagResource",
        "sns:UntagResource",
    ],
    "aws_sns_topic_subscription": [
        "sns:GetSubscriptionAttributes",
        "sns:ListTagsForResource",
        "sns:ListSubscriptionsByTopic",
        "sns:SetSubscriptionAttributes",
        "sns:Subscribe",
        "sns:Unsubscribe",
    ],
    "aws_codeartifact_domain": [
        "codeartifact:CreateDomain",
        "codeartifact:DeleteDomain",
        "codeartifact:DescribeDomain",
        "codeartifact:ListTagsForResource",
        "codeartifact:TagResource",
        "codeartifact:UntagResource",
    ],
    "aws_codeartifact_repository": [
        "codeartifact:AssociateExternalConnection",
        "codeartifact:DisassociateExternalConnection",
        "codeartifact:CreateRepository",
        "codeartifact:DeleteRepository",
        "codeartifact:DescribeRepository",
        "codeartifact:ListTagsForResource",
        "codeartifact:TagResource",
        "codeartifact:UntagResource",
        "codeartifact:UpdateRepository",
    ],
    "aws_location_place_index": [
        "geo:CreatePlaceIndex",
        "geo:DeletePlaceIndex",
        "geo:DescribePlaceIndex",
        "geo:ListTagsForResource",
        "geo:TagResource",
        "geo:UntagResource",
        "geo:UpdatePlaceIndex",
    ],
    # Optional resources inside nested registry modules. The default cell does
    # not create them. The actions are the APIs those resources call
    # (hashicorp/aws v5.100.0), not a service wildcard.
    "aws_redshift_subnet_group": [
        "redshift:CreateClusterSubnetGroup",
        "redshift:CreateTags",
        "redshift:DeleteClusterSubnetGroup",
        "redshift:DeleteTags",
        "redshift:DescribeClusterSubnetGroups",
        "redshift:ModifyClusterSubnetGroup",
    ],
    "aws_sqs_queue": [
        "sqs:CreateQueue",
        "sqs:DeleteQueue",
        "sqs:GetQueueAttributes",
        "sqs:ListQueueTags",
        "sqs:SetQueueAttributes",
        "sqs:TagQueue",
        "sqs:UntagQueue",
    ],
    "aws_sqs_queue_policy": [
        "sqs:GetQueueAttributes",
        "sqs:SetQueueAttributes",
    ],
    "aws_rolesanywhere_profile": [
        "rolesanywhere:CreateProfile",
        "rolesanywhere:DeleteProfile",
        "rolesanywhere:DisableProfile",
        "rolesanywhere:EnableProfile",
        "rolesanywhere:GetProfile",
        "rolesanywhere:ListTagsForResource",
        "rolesanywhere:TagResource",
        "rolesanywhere:UntagResource",
        "rolesanywhere:UpdateProfile",
    ],
    "aws_rolesanywhere_trust_anchor": [
        "rolesanywhere:CreateTrustAnchor",
        "rolesanywhere:DeleteTrustAnchor",
        "rolesanywhere:DisableTrustAnchor",
        "rolesanywhere:EnableTrustAnchor",
        "rolesanywhere:GetTrustAnchor",
        "rolesanywhere:ListTagsForResource",
        "rolesanywhere:TagResource",
        "rolesanywhere:UntagResource",
        "rolesanywhere:UpdateTrustAnchor",
    ],
    "aws_iam_instance_profile": [
        "iam:AddRoleToInstanceProfile",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:ListInstanceProfileTags",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:UntagInstanceProfile",
    ],
    "aws_iam_openid_connect_provider": [
        "iam:AddClientIDToOpenIDConnectProvider",
        "iam:CreateOpenIDConnectProvider",
        "iam:DeleteOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider",
        "iam:ListOpenIDConnectProviderTags",
        "iam:RemoveClientIDFromOpenIDConnectProvider",
        "iam:TagOpenIDConnectProvider",
        "iam:UntagOpenIDConnectProvider",
        "iam:UpdateOpenIDConnectProviderThumbprint",
    ],
}

IAM_STATEMENT_KIND = {
    "aws_iam_instance_profile": "instance-profile",
    "aws_iam_openid_connect_provider": "eks-oidc-provider",
}

# Representative concrete actions for IAM simulation.
SIMULATE = {
    "aws-ecs": ["ecs:CreateCluster", "ecs:RegisterTaskDefinition", "elasticloadbalancing:CreateLoadBalancer"],
    "aws-eks": ["eks:CreateCluster", "eks:DescribeCluster", "autoscaling:CreateAutoScalingGroup"],
    "aws-serverless": ["lambda:CreateFunction", "lambda:UpdateFunctionCode", "apigateway:POST"],
    "redis": ["elasticache:CreateReplicationGroup"],
    "custom-domain": ["acm:RequestCertificate", "route53:ChangeResourceRecordSets"],
    "waf": ["wafv2:AssociateWebACL", "elasticloadbalancing:CreateWebACLAssociation", "elasticloadbalancing:GetLoadBalancerWebACL"],
    "gp-batch": ["batch:CreateComputeEnvironment"],
    "iam-workload": ["iam:CreateRole", "iam:PassRole"],
}

MODULE_SPECS = {
    "aws-ecs": {
        "module": "infrastructure/terraform/modules/aws-ecs",
        "template": BOOTSTRAP / "aws-ecs" / "main.tf",
        "sids": ["EcsCoreInfra"],
        "pass_role_services": ["ecs-tasks.amazonaws.com"],
        "service_linked_roles": [
            "ecs.amazonaws.com",
            "ecs.application-autoscaling.amazonaws.com",
            "elasticloadbalancing.amazonaws.com",
            "rds.amazonaws.com",
        ],
        "attachable_policies": ["service-role/AmazonECSTaskExecutionRolePolicy"],
    },
    "aws-eks": {
        "module": "infrastructure/terraform/modules/aws-eks",
        "template": BOOTSTRAP / "aws-eks" / "main.tf",
        "sids": ["EksCoreInfra", "EksCellDataPlane"],
        "pass_role_services": [
            "ec2.amazonaws.com",
            "eks.amazonaws.com",
            "pods.eks.amazonaws.com",
        ],
        "service_linked_roles": [
            "autoscaling.amazonaws.com",
            "eks-nodegroup.amazonaws.com",
            "eks.amazonaws.com",
            "elasticloadbalancing.amazonaws.com",
            "rds.amazonaws.com",
        ],
        "attachable_policies": [
            "AmazonEC2ContainerRegistryReadOnly",
            "AmazonEKSClusterPolicy",
            "AmazonEKSVPCResourceController",
            "AmazonEKSWorkerNodePolicy",
            "AmazonEKS_CNI_Policy",
        ],
    },
    "aws-serverless": {
        "module": "infrastructure/terraform/modules/aws-serverless",
        "template": BOOTSTRAP / "aws-serverless" / "main.tf",
        "sids": ["ServerlessCoreInfra"],
        "pass_role_services": [
            "lambda.amazonaws.com",
            "rds.amazonaws.com",
            "scheduler.amazonaws.com",
        ],
        "service_linked_roles": ["rds.amazonaws.com"],
        "attachable_policies": [
            "CloudWatchLambdaInsightsExecutionRolePolicy",
            "service-role/AWSLambdaBasicExecutionRole",
            "service-role/AWSLambdaVPCAccessExecutionRole",
        ],
    },
}

FEATURE_SPECS = {
    "redis": {
        "sids_by_template": {
            BOOTSTRAP / "aws-ecs" / "main.tf": ["EcsCoreInfra"],
            BOOTSTRAP / "aws-eks" / "main.tf": ["EksCellDataPlane"],
            BOOTSTRAP / "aws-serverless" / "main.tf": ["ServerlessCoreInfra"],
        },
        "pass_role_services": [],
        "service_linked_roles": ["elasticache.amazonaws.com"],
        "attachable_policies": [],
    },
    "custom-domain": {
        "sids_by_template": {
            BOOTSTRAP / "aws-ecs" / "main.tf": ["EcsCoreInfra"],
            BOOTSTRAP / "aws-eks" / "main.tf": ["EksCellDataPlane", "EksCellDns"],
            BOOTSTRAP / "aws-serverless" / "main.tf": [
                "ServerlessCoreInfra",
                "CustomDomainDnsRecords",
                "CustomDomainDnsChanges",
                "CustomDomainDnsDiscovery",
            ],
        },
        "pass_role_services": [],
        "service_linked_roles": ["ops.apigateway.amazonaws.com"],
        "attachable_policies": [],
    },
    "waf": {
        "sids_by_template": {
            BOOTSTRAP / "aws-ecs" / "main.tf": ["EcsCoreInfra"],
        },
        "pass_role_services": [],
        "service_linked_roles": [],
        "attachable_policies": [],
    },
    "gp-batch": {
        "sids_by_template": {
            BOOTSTRAP / "aws-serverless" / "main.tf": ["GpBatchProvisioning"],
        },
        "pass_role_services": ["batch.amazonaws.com", "ecs-tasks.amazonaws.com"],
        "service_linked_roles": ["batch.amazonaws.com", "ecs.amazonaws.com"],
        "attachable_policies": [
            "service-role/AWSBatchServiceRole",
            "service-role/AmazonECSTaskExecutionRolePolicy",
        ],
    },
}

IAM_WORKLOAD_STATEMENTS = [
    {
        "sid": "CreateBoundedWorkloadRoles",
        "resource_kind": None,
        "actions": [
            "iam:CreateRole",
            "iam:DeleteRolePolicy",
            "iam:DetachRolePolicy",
            "iam:PutRolePermissionsBoundary",
            "iam:PutRolePolicy",
            "iam:UpdateAssumeRolePolicy",
            "iam:UpdateRole",
            "iam:UpdateRoleDescription",
        ],
    },
    {
        "sid": "AttachBoundedWorkloadPolicies",
        "resource_kind": None,
        "actions": ["iam:AttachRolePolicy"],
    },
    {
        "sid": "ManageWorkloadRoles",
        "resource_kind": None,
        "actions": [
            "iam:CreatePolicy",
            "iam:CreatePolicyVersion",
            "iam:DeletePolicy",
            "iam:DeletePolicyVersion",
            "iam:DeleteRole",
            "iam:GetPolicy",
            "iam:GetPolicyVersion",
            "iam:GetRole",
            "iam:GetRolePolicy",
            "iam:ListAttachedRolePolicies",
            "iam:ListInstanceProfilesForRole",
            "iam:ListPolicyVersions",
            "iam:ListPolicyTags",
            "iam:ListRolePolicies",
            "iam:ListRoleTags",
            "iam:ListRoles",
            "iam:TagPolicy",
            "iam:TagRole",
            "iam:UntagPolicy",
            "iam:UntagRole",
        ],
    },
    {
        "sid": "CreateServiceLinkedRoles",
        "resource_kind": None,
        "actions": ["iam:CreateServiceLinkedRole"],
    },
    {
        "sid": "PassWorkloadRoles",
        "resource_kind": None,
        "actions": ["iam:PassRole"],
    },
]


def service_of(resource_type: str) -> str | None:
    for prefix, service in PREFIX_SERVICE:
        if resource_type.startswith(prefix):
            return service
    return None


def feature_of(resource_type: str) -> str | None:
    service = service_of(resource_type)
    if service is None:
        return None
    for feature, services in FEATURE_SERVICES.items():
        if service in services:
            return feature
    return None


def actions_in_sids(text: str, sids: set[str]) -> list[str]:
    found: list[str] = []
    for chunk in re.split(r"\n  statement \{", text):
        match = re.search(r'sid\s*=\s*"([^"]+)"', chunk)
        if not match or match.group(1) not in sids:
            continue
        actions = chunk.split("resources", 1)[0]
        found.extend(re.findall(r'"([a-z0-9-]+:[A-Za-z0-9*]+)"', actions))
    return found


def curated_actions(paths_and_sids: dict[Path, list[str]], services: set[str]) -> list[str]:
    actions: set[str] = set()
    for path, sids in paths_and_sids.items():
        text = path.read_text(encoding="utf-8")
        for action in actions_in_sids(text, set(sids)):
            service = action.split(":", 1)[0]
            if service in services:
                actions.add(action)
    return sorted(actions)


def iter_tf(directory: Path):
    if not directory.exists():
        return
    for path in directory.rglob("*.tf"):
        if any(part in {".terraform", "examples", "tests", "test", ".git"} for part in path.relative_to(directory).parts):
            continue
        yield path


def resource_types_in(directory: Path) -> set[str]:
    types: set[str] = set()
    for path in iter_tf(directory):
        text = path.read_text(encoding="utf-8")
        types.update(re.findall(r'resource\s+"(aws_[a-z0-9_]+)"', text))
    return types


def nested_directories(module_dir: Path) -> list[Path]:
    manifest = module_dir / ".terraform" / "modules" / "modules.json"
    if not manifest.exists():
        raise SystemExit(
            f"missing {manifest}. Run terraform -chdir={module_dir.relative_to(REPO)} init -backend=false "
            "so registry modules can be scanned."
        )
    data = json.loads(manifest.read_text(encoding="utf-8"))
    found = []
    for entry in data.get("Modules", []):
        key = entry.get("Key") or ""
        if key == "":
            continue
        directory = (module_dir / entry["Dir"]).resolve()
        if directory.is_dir():
            found.append(directory)
    return found


def module_resource_types(module_rel: str) -> set[str]:
    module_dir = REPO / module_rel
    types = resource_types_in(module_dir)
    for directory in nested_directories(module_dir):
        types.update(resource_types_in(directory))
    return types


def provider_resource_types() -> set[str]:
    if not (EXEC_ROOT / ".terraform").exists():
        raise SystemExit(
            "missing aws-exec-identity/.terraform. Run terraform init -backend=false there so "
            "providers schema can be read."
        )
    raw = subprocess.check_output(
        ["terraform", f"-chdir={EXEC_ROOT}", "providers", "schema", "-json"],
        text=True,
    )
    document = json.loads(raw)
    aws = document["provider_schemas"]["registry.terraform.io/hashicorp/aws"]["resource_schemas"]
    return set(aws)


def blank_manifest(manifest_id: str, kind: str, module: str | None) -> dict:
    # Every file has the same keys and the same iam_statements element shape.
    # Terraform rejects a map of jsondecode() values when the object types differ,
    # including an empty iam_statements array next to a non-empty one.
    return {
        "id": manifest_id,
        "kind": kind,
        "module": module,
        "note": "",
        "region_actions": [],
        "global_actions": [],
        "pass_role_services": [],
        "service_linked_roles": [],
        "attachable_policies": [],
        "iam_statements": [],
        "covers": [],
        "simulate_allow": SIMULATE.get(manifest_id, []),
    }


def add_actions(manifest: dict, actions: list[str]) -> None:
    region = set(manifest["region_actions"])
    glob = set(manifest["global_actions"])
    for action in actions:
        service = action.split(":", 1)[0]
        if service == "iam":
            continue
        if service in GLOBAL_SERVICES:
            glob.add(action)
        else:
            region.add(action)
    manifest["region_actions"] = sorted(region)
    manifest["global_actions"] = sorted(glob)


def add_iam_statement(manifest: dict, resource_type: str, actions: list[str]) -> None:
    kind = IAM_STATEMENT_KIND[resource_type]
    sid = {
        "instance-profile": "ManageWorkloadInstanceProfiles",
        "eks-oidc-provider": "ManageEksOidcProviders",
    }[kind]
    existing = next((item for item in manifest["iam_statements"] if item["sid"] == sid), None)
    if existing is None:
        manifest["iam_statements"].append({
            "sid": sid,
            "resource_kind": kind,
            "actions": sorted(set(actions)),
        })
        return
    existing["actions"] = sorted(set(existing["actions"]) | set(actions))


def manifest_action_set(manifest: dict, shared_iam: set[str]) -> set[str]:
    actions = set(manifest["region_actions"]) | set(manifest["global_actions"]) | shared_iam
    for statement in manifest["iam_statements"]:
        actions.update(statement["actions"])
    return actions


def wildcard_action_problems(manifest: dict) -> list[str]:
    """Reject patterns and malformed IAM actions, including in on-disk manifests."""
    return [
        f"{manifest['id']}: action {action} must be an exact IAM action"
        for action in sorted(manifest_action_set(manifest, set()) | set(manifest.get("simulate_allow", [])))
        if not re.fullmatch(r"[a-z0-9-]+:[A-Za-z0-9]+", action)
    ]


def build() -> tuple[dict[str, dict], list[str]]:
    schema = provider_resource_types()
    shared_iam = {action for statement in IAM_WORKLOAD_STATEMENTS for action in statement["actions"]}
    manifests: dict[str, dict] = {}

    manifests["iam-workload"] = blank_manifest("iam-workload", "shared", None)
    manifests["iam-workload"]["iam_statements"] = IAM_WORKLOAD_STATEMENTS
    manifests["iam-workload"]["note"] = (
        "Always attached. Name-prefix and permissions-boundary scope stay in the root, "
        "matching the certified role. This file is the action list only."
    )

    module_types: dict[str, set[str]] = {}
    for manifest_id, spec in MODULE_SPECS.items():
        body = blank_manifest(manifest_id, "module", spec["module"])
        body["pass_role_services"] = list(spec["pass_role_services"])
        body["service_linked_roles"] = list(spec["service_linked_roles"])
        body["attachable_policies"] = list(spec["attachable_policies"])
        text_actions = []
        text = spec["template"].read_text(encoding="utf-8")
        for action in actions_in_sids(text, set(spec["sids"])):
            service = action.split(":", 1)[0]
            if any(service in group for group in FEATURE_SERVICES.values()):
                continue
            if service == "rds":
                continue
            if service == "autoscaling":
                continue
            # The Lambda module only refers to operator-provided buckets in
            # workload policies; Terraform declares no S3 resources there.
            if service == "s3" and manifest_id == "aws-serverless":
                continue
            if service == "cloudwatch" and manifest_id == "aws-eks":
                continue
            # EKS ingress is created by its Kubernetes controller. The deploy
            # role only needs the health reads used by optional ASGs below.
            if service == "elasticloadbalancing" and manifest_id == "aws-eks":
                continue
            # API Gateway TagResource authorizes PATCH/POST/PUT, already
            # present; apigateway:TagResource is not an IAM action.
            if action == "apigateway:TagResource":
                continue
            if action in {"logs:TagLogGroup", "logs:UntagLogGroup"}:
                continue
            if service == "s3" and ('*' in action or '?' in action):
                continue
            if action.startswith("ec2:") and ("*" in action or "?" in action):
                ec2_actions = EC2_VPC_ACTIONS | (EC2_EKS_ACTIONS if manifest_id == "aws-eks" else set())
                text_actions.extend(f"ec2:{name}" for name in ec2_actions if name.startswith(action[4:-1]))
                continue
            if action in PATTERN_REPLACEMENTS:
                text_actions.extend(PATTERN_REPLACEMENTS[action])
                continue
            if service in COMPUTE_EXACT_ACTIONS and ('*' in action or '?' in action):
                continue
            text_actions.append(action)
        compute_service = {"aws-ecs": "ecs", "aws-eks": "eks", "aws-serverless": "lambda"}[manifest_id]
        text_actions.extend(f"{compute_service}:{action}" for action in COMPUTE_EXACT_ACTIONS[compute_service])
        text_actions.extend(f"ec2:{action}" for action in EC2_VPC_ADDITIONAL_ACTIONS)
        if manifest_id == "aws-ecs":
            text_actions.extend(f"s3:{action}" for action in S3_BUCKET_ACTIONS)
        text_actions.extend(f"rds:{action}" for action in RDS_COMMON_ACTIONS | (RDS_PROXY_ACTIONS if manifest_id == "aws-serverless" else set()))
        if manifest_id == "aws-eks":
            text_actions.extend(f"autoscaling:{action}" for action in AUTOSCALING_ACTIONS)
            text_actions.extend(["elasticloadbalancing:DescribeInstanceHealth", "elasticloadbalancing:DescribeTargetHealth"])
        add_actions(body, text_actions)
        module_types[manifest_id] = module_resource_types(spec["module"])
        manifests[manifest_id] = body

    for feature, spec in FEATURE_SPECS.items():
        body = blank_manifest(feature, "feature", None)
        body["pass_role_services"] = list(spec["pass_role_services"])
        body["service_linked_roles"] = list(spec["service_linked_roles"])
        body["attachable_policies"] = list(spec["attachable_policies"])
        add_actions(body, FEATURE_EXACT_ACTIONS.get(feature) or
                    curated_actions(spec["sids_by_template"], FEATURE_SERVICES[feature]))
        manifests[feature] = body

    problems: list[str] = []
    covers: dict[str, set[str]] = {key: set() for key in manifests}

    for manifest_id, types in module_types.items():
        for resource_type in sorted(types):
            if resource_type not in schema:
                problems.append(f"{resource_type} is not in the AWS provider schema ({manifest_id})")
                continue
            feature = feature_of(resource_type)
            owner = feature or manifest_id
            if service_of(resource_type) == "iam" and resource_type not in EXACT_ACTIONS:
                owner = "iam-workload"
            covers[owner].add(resource_type)
            exact = EXACT_ACTIONS.get(resource_type, [])
            if resource_type in IAM_STATEMENT_KIND:
                add_iam_statement(manifests[manifest_id], resource_type, exact)
            elif exact:
                add_actions(manifests[owner], exact)

    for manifest_id, types in covers.items():
        manifests[manifest_id]["covers"] = sorted(types)

    for manifest_id, types in module_types.items():
        for resource_type in sorted(types):
            if resource_type not in schema:
                continue
            feature = feature_of(resource_type)
            owner_id = feature or manifest_id
            if service_of(resource_type) == "iam" and resource_type not in EXACT_ACTIONS:
                owner_id = "iam-workload"
            owner = manifests[owner_id]
            # Instance profiles and OIDC providers are declared on the module
            # manifest even when the cover list records them there.
            action_manifest = manifests[manifest_id] if resource_type in IAM_STATEMENT_KIND else owner
            have = manifest_action_set(action_manifest, shared_iam if owner_id == "iam-workload" or service_of(resource_type) == "iam" else set())
            if resource_type in EXACT_ACTIONS and resource_type not in IAM_STATEMENT_KIND:
                missing = [action for action in EXACT_ACTIONS[resource_type] if action not in have]
                if missing:
                    problems.append(f"{resource_type} ({manifest_id}) has no actions: {', '.join(missing)}")
                continue
            if resource_type in IAM_STATEMENT_KIND:
                missing = [action for action in EXACT_ACTIONS[resource_type] if action not in manifest_action_set(manifests[manifest_id], set())]
                if missing:
                    problems.append(f"{resource_type} ({manifest_id}) has no actions: {', '.join(missing)}")
                continue
            service = service_of(resource_type)
            if service is None:
                problems.append(f"{resource_type} ({manifest_id}) has no IAM service mapping and no actions")
                continue
            pool = have
            if not any(action.startswith(service + ":") for action in pool):
                problems.append(f"{resource_type} ({manifest_id}) has no {service}: actions")

    for manifest in manifests.values():
        manifest["iam_statements"] = sorted(manifest["iam_statements"], key=lambda item: item["sid"])
        # An empty array decodes as a different Terraform type than an array of
        # objects, so every manifest carries at least this ignored element.
        if not manifest["iam_statements"]:
            manifest["iam_statements"] = [{
                "sid": "None",
                "resource_kind": None,
                "actions": [],
            }]
    return manifests, problems


def render(manifest: dict) -> str:
    return json.dumps(manifest, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write", action="store_true")
    group.add_argument("--check", action="store_true")
    args = parser.parse_args()

    manifests, problems = build()
    for body in manifests.values():
        problems.extend(wildcard_action_problems(body))
    if args.check:
        for path in MANIFEST_DIR.glob("*.json"):
            problems.extend(wildcard_action_problems(json.loads(path.read_text(encoding="utf-8"))))
    if problems:
        for problem in problems:
            print(f"::error::{problem}", file=sys.stderr)
        return 1

    MANIFEST_DIR.mkdir(parents=True, exist_ok=True)
    written = []
    drift = []
    for manifest_id, body in sorted(manifests.items()):
        path = MANIFEST_DIR / f"{manifest_id}.json"
        text = render(body)
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                drift.append(path.name)
        else:
            path.write_text(text, encoding="utf-8")
            written.append(path.name)

    if drift:
        print("manifests differ from the generator: " + ", ".join(drift), file=sys.stderr)
        print("run generate-deploy-identity-manifests.py --write", file=sys.stderr)
        return 1
    counts = {key: len(body["region_actions"]) + len(body["global_actions"]) for key, body in manifests.items()}
    print("manifests " + ("ok" if args.check else "written") + ": " + ", ".join(
        f"{key}={counts[key]}" for key in sorted(counts)
    ))
    for key, body in sorted(manifests.items()):
        if body["covers"]:
            print(f"  {key} covers {len(body['covers'])} resource types")
    return 0


if __name__ == "__main__":
    sys.exit(main())
