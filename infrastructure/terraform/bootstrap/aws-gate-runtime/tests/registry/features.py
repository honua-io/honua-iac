"""Retain AWS feature switches without copying deployment code or identifiers."""
from copy import deepcopy
import re

from actions import authorization_actions
from scope import OPTIONAL, arn_service
from runtime import custom_actions

REQUEST_PATHS = {
    "AWS::IAM::Role": ["PermissionsBoundary"],
    "AWS::Events::Rule": ["EventBusName"],
    "AWS::Batch::JobDefinition": ["ConsumableResourceProperties"],
}


def synthetic(value):
    service = arn_service(value)
    if service:
        return "arn:aws:" + service + ":synthetic"
    if isinstance(value, dict):
        if value == {"Ref": "AWS::NoValue"}:
            return value
        if "Fn::If" in value:
            return {"Fn::If": ["AuditCondition", *map(synthetic, value["Fn::If"][1:])]}
        return {"Ref": "AuditUnknown"}
    if isinstance(value, list):
        return [synthetic(item) for item in value]
    if isinstance(value, str) and value.startswith("arn:"):
        parts = value.split(":")
        return ":".join(parts[:3] + ["synthetic"] * (len(parts) - 3))
    values = {expression.split("=", 1)[1] for _, _, paths in OPTIONAL
              for expression in paths if "=" in expression}
    return value if value in {True, False, None, "", "default", *values} else "synthetic"


def project_path(source, path):
    name, *rest = path
    if name not in source:
        return {}
    value = source[name]
    if rest and isinstance(value, dict) and not any(
        key == "Ref" or key.startswith("Fn::") for key in value
    ):
        return {name: project_path(value, rest)}
    return {name: synthetic(value)}


def merge_paths(left, right):
    result = deepcopy(left)
    for key, value in right.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = merge_paths(result[key], value)
        else:
            result[key] = value
    return result


def project_resource(resource):
    properties = {}
    for suffix, _, paths in OPTIONAL:
        if resource["Type"] == "AWS::" + suffix:
            for expression in paths:
                path = re.split("[=~]", expression, maxsplit=1)[0]
                properties = merge_paths(properties, project_path(resource.get("Properties", {}), path.split(".")))
    for path in REQUEST_PATHS.get(resource["Type"], []):
        properties = merge_paths(properties, project_path(resource.get("Properties", {}), path.split(".")))
    return {"Type": resource["Type"], "Properties": properties}


def project_snapshot(snapshot):
    result = deepcopy(snapshot)
    runtime_actions, custom_types = set(), {}
    for template in result["templates"]:
        resources, projected = template["resources"], {}
        for index, resource in enumerate(resources.values(), 1):
            item = project_resource(resource)
            if resource["Type"].startswith("Custom::"):
                custom_type = custom_types.setdefault(resource["Type"], f"Custom::Audit{len(custom_types) + 1:03}")
                item["Type"] = custom_type
                calls = custom_actions(resource, resources, snapshot["authorization"])
                if calls is not None:
                    item["AuditRuntimeActions"] = calls
                    runtime_actions.update(calls)
            projected[f"Resource{index:03}"] = item
        template["resources"] = projected
    actions = runtime_actions | {action for schema in snapshot["schemas"].values()
               for permissions in [*schema["handlers"].values(), schema.get("tagging", {}).get("permissions", [])]
               for a in permissions for action in authorization_actions(a)}
    actions = {action.lower() for action in actions}
    for prefix, service in result["authorization"].items():
        service["Actions"] = [
            {k: v for k, v in action.items() if k in {"Name", "ActionConditionKeys", "Resources"}}
            for action in service["Actions"] if f'{prefix}:{action["Name"]}'.lower() in actions
        ]
        names = {r["Name"] for action in service["Actions"] for r in action.get("Resources", [])}
        service["Resources"] = [r for r in service.get("Resources", []) if r["Name"] in names]
        for key in list(service):
            if key not in {"Actions", "Resources"}:
                del service[key]
    return result
