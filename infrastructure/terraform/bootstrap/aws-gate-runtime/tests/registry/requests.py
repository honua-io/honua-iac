"""Build synthetic handler requests using AWS authorization resource metadata."""
import re

ACCOUNT = "000000000002"
RESOURCE_NAMES = {
    "DBInstance": "db", "DBParameterGroup": "pg", "DBSubnetGroup": "subgrp",
    "LoadBalancer": "loadbalancer/app/", "Listener": "listener/app", "ListenerRule": "listener-rule/app",
    "UserPool": "userpool", "UserPoolClient": "userpool", "UserPoolDomain": "userpool",
    "UserPoolGroup": "userpool", "UserPoolUser": "userpool", "UserPoolUserToGroupAttachment": "userpool",
    "ScalableTarget": "ScalableTarget", "ScalingPolicy": "ScalableTarget",
    "BackupPlan": "backupPlan", "BackupSelection": "backupPlan", "BackupVault": "backupVault",
    "Policy": "role", "Role": "role", "LogGroup": "log-group",
    "RecordSet": "hostedzone", "HealthCheck": "healthcheck", "HostedZone": "hostedzone",
    "QueuePolicy": "queue", "Subscription": "topic", "TopicPolicy": "topic",
    "BucketPolicy": "bucket", "Bucket": "bucket", "Alias": "alias", "Certificate": "certificate",
    "Function": "function", "Key": "key", "Parameter": "parameter",
    "JobDefinition": "job-definition-revision", "CompositeAlarm": "alarm",
    "EIP": "elastic-ip", "FlowLog": "vpc-flow-log", "SecurityGroupEgress": "security-group",
}
PARENT_CREATES = {
    "cognito-idp:CreateUserPoolClient", "cognito-idp:CreateUserPoolDomain", "cognito-idp:CreateGroup",
    "elasticloadbalancing:CreateListener", "elasticloadbalancing:CreateRule",
    "backup:CreateBackupSelection", "ec2:CreateRoute", "ec2:CreateNetworkAclEntry",
    "kms:CreateGrant", "elasticloadbalancing:RegisterTargets",
}


def resource_for(resource_type, action, service):
    name = action.split(":", 1)[1].lower()
    api = next((a for a in service["Actions"] if a["Name"].lower() == name), None)
    if api is None:
        return None
    available = {r["Name"] for r in api.get("Resources", [])}
    if not available:
        return api, None
    suffix = resource_type.split("::")[-1]
    preferred = RESOURCE_NAMES.get(suffix, suffix.lower())
    if resource_type.startswith("Audit::"):
        preferred = suffix
        if preferred not in available:
            raise ValueError(f"Unsupported authorization resource: {action} {preferred}")
    if action.lower() == "cloudwatch:putmetricalarm":
        preferred = "alarm"
    if action.lower().startswith("s3:getobject") or action.lower() in {"s3:putobjectacl", "s3:deleteobject", "s3:putobject"}:
        preferred = "object"
    selected = next((r for r in service.get("Resources", []) if r["Name"] in available and
                     r["Name"].lower().replace("-", "") == preferred.lower().replace("-", "")), None)
    if selected is None:
        if len(available) != 1:
            raise ValueError(f"Unmapped resource selection: {resource_type} {action}: {sorted(available)}")
        selected = next(r for r in service["Resources"] if r["Name"] in available)
    return api, selected


def synthetic_arn(resource):
    if resource is None:
        return "*"
    replacements = {"Partition": "aws", "Region": "us-east-1", "Account": ACCOUNT,
                    "AccountId": ACCOUNT, "AccountID": ACCOUNT,
                    "ParameterNameWithoutLeadingSlash": "honua/honua-gate-audit/watchdog/state",
                    "LogGroupName": "/honua/honua-gate-audit/audit"}
    return re.sub(r"\$\{([^}]+)\}", lambda m: replacements.get(m[1], "honua-gate-audit"), resource["ARNFormats"][0])


def request_for(spec, service):
    resource_type, handler, action, schema = (spec[k] for k in ("type", "handler", "action", "schema"))
    metadata_type = "Audit::" + spec["resource_name"] if "resource_name" in spec else resource_type
    metadata = resource_for(metadata_type, action, service)
    if metadata is None:
        return None
    api, resource = metadata
    keys = api.get("ActionConditionKeys", []) + [
        key for entry in api.get("Resources", [])
        if resource and entry["Name"] == resource["Name"]
        for key in entry.get("ConditionKeys", resource.get("ConditionKeys", []))
    ]
    context = {"aws:RequestedRegion": "us-east-1"}
    allocation = handler == "create" and action not in PARENT_CREATES and (
        action.split(":")[1].startswith(("Create", "Register", "Request", "Allocate", "Restore")) or
        (action.lower() in {"ec2:createtags", "rds:addtagstoresource"}))
    if "aws:ResourceTag/${TagKey}" in keys and not allocation:
        context["aws:ResourceTag/HonuaGate"] = "true"
        if schema.get("tagging", {}).get("cloudFormationSystemTags", True):
            context["aws:ResourceTag/aws:cloudformation:stack-name"] = "honua-gate-audit"
    if "aws:RequestTag/${TagKey}" in keys:
        context["aws:RequestTag/HonuaGate"] = "true"
        if schema.get("tagging", {}).get("cloudFormationSystemTags", True):
            context["aws:RequestTag/aws:cloudformation:stack-name"] = "honua-gate-audit"
    if action.lower() == "ec2:createtags" and handler == "create":
        context["ec2:CreateAction"] = "CreateVpc"
    if action.lower() in {"iam:createrole", "iam:putrolepermissionsboundary"}:
        boundary = spec.get("properties", {}).get("PermissionsBoundary")
        if boundary is not None:
            raise ValueError("Unresolved deployment permissions boundary")
    if action.lower() == "iam:passrole":
        context["iam:PassedToService"] = "lambda.amazonaws.com"
    if action.lower() == "iam:createservicelinkedrole":
        raise ValueError("Unresolved provider service-linked-role identity")
    return action, synthetic_arn(resource), context
