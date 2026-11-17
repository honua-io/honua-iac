"""Expand API calls that authorize more than one resource.

KMS alias operations authorize the alias and each affected key separately:
https://docs.aws.amazon.com/kms/latest/developerguide/alias-access.html
"""
from requests import request_for
from scope import property_present

# The subnet association template cannot target a gateway or an IPAM pool.
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html
MULTI_RESOURCE = {
    "ec2:AssociateRouteTable": ("route-table", "subnet"),
    "ec2:ReplaceRouteTableAssociation": ("route-table", "subnet"),
    "ec2:DisassociateRouteTable": ("route-table", "subnet"),
    "ec2:AttachInternetGateway": ("internet-gateway", "vpc"),
    "ec2:DetachInternetGateway": ("internet-gateway", "vpc"),
    "ec2:AttachVpnGateway": ("vpn-gateway", "vpc"),
    "ec2:DetachVpnGateway": ("vpn-gateway", "vpc"),
}


def creation_resources(spec, service):
    action = spec["action"].lower()
    if action in {"elasticloadbalancing:createlistener", "elasticloadbalancing:createrule"}:
        # Audit all parent variants when the ARN cannot be resolved offline.
        api = next(item for item in service["Actions"] if item["Name"].lower() == action.split(":")[1])
        return [item["Name"] for item in api["Resources"]]
    if action == "batch:registerjobdefinition":
        names = ["job-definition"]
        if property_present(spec.get("properties", {}), ["ConsumableResourceProperties"]):
            names.append("consumable-resource")
        return names
    return None


def operation_requests(spec, service):
    names = creation_resources(spec, service)
    if names:
        return [request_for({**spec, "resource_name": name}, service) for name in names]
    if spec["type"] == "AWS::Events::Rule" and spec["action"].startswith("events:"):
        bus = spec.get("properties", {}).get("EventBusName", "default")
        if not isinstance(bus, str):
            raise ValueError("Unmapped event bus expression")
        spec = {**spec, "resource_name": "rule-on-default-event-bus" if bus == "default"
                else "rule-on-custom-event-bus"}
    if spec["action"] in MULTI_RESOURCE:
        return [request_for({**spec, "resource_name": name}, service)
                for name in MULTI_RESOURCE[spec["action"]]]
    request = request_for(spec, service)
    if request is None:
        return None
    requests = [request]
    if spec["action"] in {"kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias"}:
        key_spec = {**spec, "type": "AWS::KMS::Key", "handler": "update"}
        action, arn, context = request_for(key_spec, service)
        targets = ["current", "new"] if spec["action"] == "kms:UpdateAlias" else ["current" if spec["action"] == "kms:DeleteAlias" else "new"]
        requests.extend((action, arn + "-" + target, context) for target in targets)
    return requests
