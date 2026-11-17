"""A parent-resource allow must not hide denial on another affected resource."""
import json
from pathlib import Path
import unittest

from audit import evaluate


class MultiResourceTests(unittest.TestCase):
    def test_ec2_associations_require_both_owned_resources(self):
        snapshot = json.loads(Path(__file__).with_name("launch-stack.json").read_text())
        cases = [
            ("SubnetRouteTableAssociation", "AssociateRouteTable", "route-table", "subnet"),
            ("SubnetRouteTableAssociation", "ReplaceRouteTableAssociation", "route-table", "subnet"),
            ("SubnetRouteTableAssociation", "DisassociateRouteTable", "route-table", "subnet"),
            ("VPCGatewayAttachment", "AttachInternetGateway", "internet-gateway", "vpc"),
            ("VPCGatewayAttachment", "DetachInternetGateway", "internet-gateway", "vpc"),
            ("VPCGatewayAttachment", "AttachVpnGateway", "vpn-gateway", "vpc"),
            ("VPCGatewayAttachment", "DetachVpnGateway", "vpn-gateway", "vpc"),
        ]
        for resource_type, action, first, second in cases:
            with self.subTest(action=action):
                spec = {"type": "AWS::EC2::" + resource_type, "handler": "update",
                        "action": "ec2:" + action, "schema": {}}
                policy = [{"Effect": "Allow", "Action": "ec2:" + action,
                           "Resource": f"arn:aws:ec2:*:*:{first}/*"}]
                requests, result = evaluate(spec, snapshot["authorization"]["ec2"], policy)
                self.assertEqual("ImplicitDeny", result)
                self.assertEqual(2, len(requests))
                self.assertIn(f":{second}/", requests[1][1])
                policy.append({"Effect": "Allow", "Action": "ec2:" + action,
                               "Resource": f"arn:aws:ec2:*:*:{second}/*"})
                self.assertEqual("Allow", evaluate(spec, snapshot["authorization"]["ec2"], policy)[1])

    def test_default_and_custom_event_bus_rules_have_distinct_resources(self):
        snapshot = json.loads(Path(__file__).with_name("launch-stack.json").read_text())
        for properties, suffix in [({}, "rule/honua-gate-audit"),
                                   ({"EventBusName": "custom"}, "rule/honua-gate-audit/honua-gate-audit")]:
            with self.subTest(properties=properties):
                spec = {"type": "AWS::Events::Rule", "handler": "create",
                        "action": "events:PutRule", "schema": {}, "properties": properties}
                requests, result = evaluate(spec, snapshot["authorization"]["events"], [
                    {"Effect": "Allow", "Action": "events:PutRule", "Resource": "*"}])
                self.assertEqual("Allow", result)
                self.assertTrue(requests[0][1].endswith(":" + suffix), requests)

    def test_creation_authorizes_parent_and_optional_consumable_resources(self):
        snapshot = json.loads(Path(__file__).with_name("launch-stack.json").read_text())
        cases = [
            ("AWS::ElasticLoadBalancingV2::Listener", "elasticloadbalancing:CreateListener", {}, 3, ":loadbalancer/"),
            ("AWS::ElasticLoadBalancingV2::ListenerRule", "elasticloadbalancing:CreateRule", {}, 2, ":listener/"),
            ("AWS::Batch::JobDefinition", "Batch:RegisterJobDefinition", {}, 1, ":job-definition/"),
            ("AWS::Batch::JobDefinition", "batch:RegisterJobDefinition", {"ConsumableResourceProperties": {"Ref": "Unknown"}}, 2, ":job-definition/"),
        ]
        for resource_type, action, properties, count, arn_kind in cases:
            with self.subTest(action=action, properties=properties):
                spec = {"type": resource_type, "handler": "create", "action": action,
                        "properties": properties, "schema": {}}
                requests, result = evaluate(spec, snapshot["authorization"][action.split(":")[0].lower()], [
                    {"Effect": "Allow", "Action": action, "Resource": "*"}])
                self.assertEqual("Allow", result)
                self.assertEqual(count, len(requests))
                self.assertIn(arn_kind, requests[0][1])
