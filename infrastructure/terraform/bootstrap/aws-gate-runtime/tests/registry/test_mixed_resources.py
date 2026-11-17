"""A single API request can allocate a child and authorize an existing parent."""
import json
from pathlib import Path
import unittest

from audit import evaluate
from operations import operation_requests


class MixedResourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.service = json.loads(Path(__file__).with_name('launch-stack.json').read_text())['authorization']['ec2']

    def cases(self):
        return [('SecurityGroupIngress', 'AuthorizeSecurityGroupIngress', 'security-group-rule', 'security-group'),
                ('SecurityGroupEgress', 'AuthorizeSecurityGroupEgress', 'security-group-rule', 'security-group'),
                ('SecurityGroup', 'CreateSecurityGroup', 'security-group', 'vpc'),
                ('RouteTable', 'CreateRouteTable', 'route-table', 'vpc')]

    def test_new_resource_has_no_ownership_but_existing_parent_does(self):
        for kind, action, created, parent in self.cases():
            with self.subTest(action=action):
                spec = {'type': 'AWS::EC2::' + kind, 'action': 'ec2:' + action,
                        'handler': 'update', 'schema': {}}
                requests = operation_requests(spec, self.service)
                self.assertEqual(2, len(requests))
                allocated = next(r for r in requests if ':' + created + '/' in r[1])
                existing = next(r for r in requests if ':' + parent + '/' in r[1])
                self.assertNotIn('aws:ResourceTag/HonuaGate', allocated[2])
                self.assertEqual('true', existing[2]['aws:ResourceTag/HonuaGate'])

    def test_permission_on_only_one_resource_is_insufficient(self):
        for kind, action, created, parent in self.cases():
            with self.subTest(action=action):
                spec = {'type': 'AWS::EC2::' + kind, 'action': 'ec2:' + action,
                        'handler': 'create', 'schema': {}}
                resources = ['arn:aws:ec2:*:*:' + name + '/*' for name in (created, parent)]
                policy = [{'Effect': 'Allow', 'Action': spec['action'], 'Resource': resources[0]}]
                self.assertEqual('ImplicitDeny', evaluate(spec, self.service, policy)[1])
                policy[0]['Resource'] = resources
                self.assertEqual('Allow', evaluate(spec, self.service, policy)[1])
