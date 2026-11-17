"""Lambda code deployment authorizes its package and signing resources."""
import json
from pathlib import Path
import unittest

from audit import evaluate
from operations import operation_requests


class LambdaTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.services = json.loads(Path(__file__).with_name('launch-stack.json').read_text())['authorization']

    def test_signing_attachment_requires_function_and_configuration(self):
        action = 'lambda:PutFunctionCodeSigningConfig'
        for handler in ('create', 'update', 'delete'):
            with self.subTest(handler=handler):
                spec = {'type': 'AWS::Lambda::Function', 'handler': handler,
                        'action': action, 'schema': {}}
                requests = operation_requests(spec, self.services['lambda'])
                arns = [request[1] for request in requests]
                self.assertEqual(2, len(arns))
                self.assertTrue(any(':function:' in arn for arn in arns))
                self.assertTrue(any(':code-signing-config:' in arn for arn in arns))
                policy = [{'Effect': 'Allow', 'Action': action, 'Resource': arns}]
                self.assertEqual('Allow', evaluate(spec, self.services['lambda'], policy)[1])
                for arn in arns:
                    partial = [{'Effect': 'Allow', 'Action': action,
                                'Resource': [item for item in arns if item != arn]}]
                    self.assertEqual('ImplicitDeny', evaluate(spec, self.services['lambda'], partial)[1])
                    denied = policy + [{'Effect': 'Deny', 'Action': action, 'Resource': arn}]
                    self.assertEqual('Deny', evaluate(spec, self.services['lambda'], denied)[1])

    def test_package_reads_use_bucket_objects(self):
        for action in ('s3:GetObject', 's3:GetObjectVersion'):
            for handler in ('create', 'update'):
                with self.subTest(action=action, handler=handler):
                    spec = {'type': 'AWS::Lambda::Function', 'handler': handler,
                            'action': action, 'schema': {}}
                    requests = operation_requests(spec, self.services['s3'])
                    self.assertEqual(['arn:aws:s3:::honua-gate-audit/honua-gate-audit'],
                                     [request[1] for request in requests])
                    policy = [{'Effect': 'Allow', 'Action': action, 'Resource': requests[0][1]}]
                    self.assertEqual('Allow', evaluate(spec, self.services['s3'], policy)[1])
                    policy.append({'Effect': 'Deny', 'Action': action, 'Resource': requests[0][1]})
                    self.assertEqual('Deny', evaluate(spec, self.services['s3'], policy)[1])
