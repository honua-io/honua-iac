"""Native trail handlers authorize trails rather than event data stores."""
import json
from pathlib import Path
import unittest

from audit import evaluate
from operations import operation_requests


class TrailTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.service = json.loads(Path(__file__).with_name('launch-stack.json').read_text())['authorization']['cloudtrail']

    def test_trail_configuration_uses_the_trail_endpoint(self):
        for action in ('GetEventConfiguration', 'PutEventConfiguration',
                       'GetInsightSelectors', 'PutInsightSelectors'):
            for handler in ('create', 'read', 'update', 'delete'):
                with self.subTest(action=action, handler=handler):
                    spec = {'type': 'AWS::CloudTrail::Trail', 'handler': handler,
                            'action': 'CloudTrail:' + action, 'schema': {}}
                    requests = operation_requests(spec, self.service)
                    arn = 'arn:aws:cloudtrail:us-east-1:000000000002:trail/honua-gate-audit'
                    self.assertEqual([arn], [request[1] for request in requests])
                    policy = [{'Effect': 'Allow', 'Action': spec['action'], 'Resource': arn}]
                    self.assertEqual('Allow', evaluate(spec, self.service, policy)[1])
                    self.assertEqual('ImplicitDeny', evaluate(spec, self.service, [])[1])
                    policy.append({'Effect': 'Deny', 'Action': spec['action'], 'Resource': arn})
                    self.assertEqual('Deny', evaluate(spec, self.service, policy)[1])

    def test_other_native_resources_do_not_assume_a_trail_identity(self):
        for resource_type in ('AWS::CloudTrail::EventDataStore', 'AWS::CloudTrail::Unknown'):
            with self.subTest(resource_type=resource_type):
                spec = {'type': resource_type, 'handler': 'read',
                        'action': 'cloudtrail:GetInsightSelectors', 'schema': {}}
                policy = [{'Effect': 'Allow', 'Action': '*', 'Resource': '*'}]
                self.assertNotEqual('Allow', evaluate(spec, self.service, policy)[1])
