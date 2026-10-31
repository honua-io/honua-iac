#!/usr/bin/env python3
"""Build and check topology deploy-identity action manifests.

The manifests are the allow-list bootstrap/aws-exec-identity assembles. Service
actions are the curated allows from the long-lived bootstrap templates
(bootstrap/aws-ecs, aws-eks, aws-serverless), split into one file per module
and one file per optional feature. A resource type the module (or a registry
module it calls) declares must map to at least one IAM action in the manifest
that owns it. terraform providers schema confirms the type is a real AWS
provider resource.

  python3 generate-deploy-identity-manifests.py --write
  python3 generate-deploy-identity-manifests.py --check

--check exits non-zero when a resource type has no actions, a type is not in
the provider schema, or the files on disk differ from what this script writes.
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
        "batch:TagResource", "batch:UntagResource",
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
        "RegisterTaskDefinition", "DeregisterTaskDefinition", "DescribeTaskDefinition",
        "ListTagsForResource", "TagResource", "UntagResource",
    ],
    "eks": [
        "CreateAccessEntry", "DeleteAccessEntry", "DescribeAccessEntry", "UpdateAccessEntry",
        "AssociateAccessPolicy", "DisassociateAccessPolicy", "ListAssociatedAccessPolicies",
        "CreateAddon", "DeleteAddon", "DescribeAddon", "UpdateAddon", "DescribeUpdate",
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
        "AddPermission", "GetPolicy", "RemovePermission", "TagResource", "UntagResource", "ListTags",
    ],
}
GLOBAL_SERVICES = {"route53"}

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

# Actions a wildcard in the curated list does not cover. The generator adds
# them to the manifest that owns the resource type.
EXACT_ACTIONS = {
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
        "codeartifact:CreateRepository",
        "codeartifact:DeleteRepository",
        "codeartifact:DescribeRepository",
        "codeartifact:ListTagsForResource",
        "codeartifact:TagResource",
        "codeartifact:UntagResource",
    ],
    "aws_location_place_index": [
        "geo:CreatePlaceIndex",
        "geo:DeletePlaceIndex",
        "geo:DescribePlaceIndex",
        "geo:ListTagsForResource",
        "geo:TagResource",
        "geo:UntagResource",
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
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:UntagInstanceProfile",
    ],
    "aws_iam_openid_connect_provider": [
        "iam:AddClientIDToOpenIDConnectProvider",
        "iam:CreateOpenIDConnectProvider",
        "iam:DeleteOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider",
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

# Concrete actions the simulator can evaluate. Wildcards stay in the policy;
# SimulateCustomPolicy wants a real action name.
SIMULATE = {
    "aws-ecs": ["ecs:CreateCluster", "ecs:RegisterTaskDefinition", "elasticloadbalancing:CreateLoadBalancer"],
    "aws-eks": ["eks:CreateCluster", "eks:DescribeCluster", "autoscaling:CreateAutoScalingGroup"],
    "aws-serverless": ["lambda:CreateFunction", "lambda:UpdateFunctionCode", "apigateway:POST"],
    "redis": ["elasticache:CreateReplicationGroup"],
    "custom-domain": ["acm:RequestCertificate", "route53:ChangeResourceRecordSets"],
    "waf": ["wafv2:CreateWebACL"],
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
            "iam:ListRolePolicies",
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
    """Reject IAM action patterns, including in on-disk manifests checked for drift."""
    return [
        f"{manifest['id']}: wildcard action {action} is not allowed"
        for action in sorted(manifest_action_set(manifest, set()))
        if '*' in action or '?' in action
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
            if service in COMPUTE_EXACT_ACTIONS and ('*' in action or '?' in action):
                continue
            text_actions.append(action)
        compute_service = {"aws-ecs": "ecs", "aws-eks": "eks", "aws-serverless": "lambda"}[manifest_id]
        text_actions.extend(f"{compute_service}:{action}" for action in COMPUTE_EXACT_ACTIONS[compute_service])
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
