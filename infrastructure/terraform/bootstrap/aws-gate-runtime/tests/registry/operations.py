"""Expand API calls that authorize more than one resource.

KMS alias operations authorize the alias and each affected key separately:
https://docs.aws.amazon.com/kms/latest/developerguide/alias-access.html
"""
from requests import request_for
from scope import property_present
from tag_targets import ec2_tag_requests, first_tag, tag_target
from native_targets import native_target

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

# The first resource is allocated; the second already exists.
# https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_AuthorizeSecurityGroupIngress.html
# https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_CreateSecurityGroup.html
MIXED_RESOURCES = {
    "ec2:AuthorizeSecurityGroupIngress": ("security-group-rule", "security-group"),
    "ec2:AuthorizeSecurityGroupEgress": ("security-group-rule", "security-group"),
    "ec2:CreateSecurityGroup": ("security-group", "vpc"),
    "ec2:CreateRouteTable": ("route-table", "vpc"),
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
    if spec["action"] in MIXED_RESOURCES:
        return [request_for({**spec, "resource_name": name, "allocation": index == 0}, service)
                for index, name in enumerate(MIXED_RESOURCES[spec["action"]])]
    if requests := ec2_tag_requests(spec, service):
        return requests
    if target := tag_target(spec):
        spec = {**spec, "resource_name": target, "first_tag": first_tag(spec)}
    if target := native_target(spec):
        spec = {**spec, "resource_name": target}
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
    api = next((item for item in service["Actions"]
                if item["Name"].lower() == spec["action"].split(":")[1].lower()), None)
    alias_actions = {"kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias"}
    if (api and len(api.get("Resources", [])) > 1 and
            "resource_name" not in spec and spec["action"] not in alias_actions):
        raise ValueError("Unmapped multi-resource authorization: " + spec["action"])
    request = request_for(spec, service)
    if request is None:
        return None
    return alias_requests(spec, service, request)


def alias_requests(spec, service, request):
    requests = [request]
    if spec["action"] in {"kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias"}:
        key_spec = {**spec, "type": "AWS::KMS::Key", "handler": "update"}
        action, arn, context = request_for(key_spec, service)
        targets = ["current", "new"] if spec["action"] == "kms:UpdateAlias" else ["current" if spec["action"] == "kms:DeleteAlias" else "new"]
        requests.extend((action, arn + "-" + target, context) for target in targets)
    return requests
