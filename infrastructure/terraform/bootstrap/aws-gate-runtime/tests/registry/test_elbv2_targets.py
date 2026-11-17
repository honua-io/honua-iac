"""Native ELBv2 operations check every supported ARN variant."""
import json
from pathlib import Path
import unittest

from audit import evaluate
from operations import operation_requests


class LoadBalancerTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.service = json.loads(Path(__file__).with_name('launch-stack.json').read_text())['authorization']['elasticloadbalancing']

    def spec(self, kind, action, handler='update'):
        return {'type': 'AWS::ElasticLoadBalancingV2::' + kind, 'handler': handler,
                'action': 'elasticloadbalancing:' + action, 'schema': {}}

    def test_native_operations_check_all_variants_and_propagate_denials(self):
        cases = [('LoadBalancer', 'CreateLoadBalancer', 'create', 'loadbalancer/', 3),
                 ('LoadBalancer', 'DeleteLoadBalancer', 'delete', 'loadbalancer/', 3),
                 ('LoadBalancer', 'ModifyLoadBalancerAttributes', 'update', 'loadbalancer/', 3),
                 ('LoadBalancer', 'ModifyCapacityReservation', 'update', 'loadbalancer/', 3),
                 ('LoadBalancer', 'SetSecurityGroups', 'update', 'loadbalancer/', 2),
                 ('LoadBalancer', 'SetSubnets', 'update', 'loadbalancer/', 3),
                 ('LoadBalancer', 'SetIpAddressType', 'update', 'loadbalancer/', 3),
                 ('Listener', 'ModifyListener', 'update', 'listener/', 3),
                 ('Listener', 'ModifyListenerAttributes', 'update', 'listener/', 3),
                 ('Listener', 'DeleteListener', 'delete', 'listener/', 3),
                 ('ListenerRule', 'ModifyRule', 'update', 'listener-rule/', 2),
                 ('ListenerRule', 'SetRulePriorities', 'update', 'listener-rule/', 2),
                 ('ListenerRule', 'DeleteRule', 'delete', 'listener-rule/', 2)]
        for kind, action, handler, prefix, count in cases:
            with self.subTest(kind=kind, action=action):
                spec = self.spec(kind, action, handler)
                requests = operation_requests(spec, self.service)
                self.assertEqual(count, len(requests))
                self.assertTrue(all(':' + prefix in r[1] for r in requests))
                self.assertTrue(all(':loadbalancer/honua-' not in r[1] for r in requests))
                policy = [{'Effect': 'Allow', 'Action': spec['action'], 'Resource': [r[1] for r in requests]}]
                self.assertEqual('Allow', evaluate(spec, self.service, policy)[1])
                policy[0]['Resource'] = [r[1] for r in requests[:-1]]
                self.assertEqual('ImplicitDeny', evaluate(spec, self.service, policy)[1])
                policy[0]['Resource'] = '*'
                policy.append({'Effect': 'Deny', 'Action': spec['action'], 'Resource': requests[-1][1]})
                self.assertEqual('Deny', evaluate(spec, self.service, policy)[1])

    def test_tagging_uses_only_its_native_type_and_first_tags_have_no_ownership(self):
        for kind, prefix, count in [('LoadBalancer', 'loadbalancer/', 3), ('Listener', 'listener/', 3),
                                    ('ListenerRule', 'listener-rule/', 2), ('TargetGroup', 'targetgroup/', 1)]:
            for handler, action in [('create', 'AddTags'), ('update', 'AddTags'), ('update', 'RemoveTags')]:
                with self.subTest(kind=kind, handler=handler, action=action):
                    requests = operation_requests(self.spec(kind, action, handler), self.service)
                    self.assertEqual(count, len(requests))
                    self.assertTrue(all(':' + prefix in r[1] for r in requests))
                    for _, _, context in requests:
                        self.assertEqual(handler != 'create', 'aws:ResourceTag/HonuaGate' in context)

    def test_unknown_type_stays_unresolved(self):
        spec = self.spec('Unknown', 'AddTags')
        self.assertNotEqual('Allow', evaluate(spec, self.service, [{'Effect': 'Allow', 'Action': '*', 'Resource': '*'}])[1])
