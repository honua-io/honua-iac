"""Native resource handlers select endpoints, not unrelated access-point variants."""
import json
from pathlib import Path
import unittest

from audit import evaluate
from operations import operation_requests
from requests import synthetic_arn


class NativeTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.services = json.loads(Path(__file__).with_name('launch-stack.json').read_text())['authorization']

    def test_bucket_handler_uses_bucket_and_object_endpoints(self):
        cases = {'ListBucket': 'bucket', 'GetBucketPolicy': 'bucket', 'GetBucketCORS': 'bucket',
                 'GetBucketNotification': 'bucket', 'GetBucketAcl': 'bucket', 'PutObjectAcl': 'object',
                 'DeleteObject': 'object', 'GetObject': 'object', 'GetObjectVersion': 'object'}
        for action, target in cases.items():
            with self.subTest(action=action):
                spec = {'type': 'AWS::S3::Bucket', 'handler': 'update', 'action': 's3:' + action, 'schema': {}}
                requests = operation_requests(spec, self.services['s3'])
                self.assertEqual(1, len(requests))
                arn = 'arn:aws:s3:::honua-gate-audit' + ('/honua-gate-audit' if target == 'object' else '')
                self.assertEqual(arn, requests[0][1])
                policy = [{'Effect': 'Allow', 'Action': spec['action'], 'Resource': arn}]
                self.assertEqual('Allow', evaluate(spec, self.services['s3'], policy)[1])
                policy.append({'Effect': 'Deny', 'Action': spec['action'], 'Resource': arn})
                self.assertEqual('Deny', evaluate(spec, self.services['s3'], policy)[1])

    def test_bucket_adapter_does_not_assume_access_point_resource_identity(self):
        spec = {'type': 'AWS::S3::AccessPoint', 'handler': 'update', 'action': 's3:ListBucket', 'schema': {}}
        policy = [{'Effect': 'Allow', 'Action': '*', 'Resource': '*'}]
        self.assertNotEqual('Allow', evaluate(spec, self.services['s3'], policy)[1])


class BucketPolicyTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.service = json.loads(Path(__file__).with_name('launch-stack.json').read_text())['authorization']['s3']

    def test_bucket_policy_read_authorizes_its_bucket(self):
        resource = next(item for item in self.service['Resources'] if item['Name'] == 'bucket')
        arn = synthetic_arn(resource)
        for handler in ('create', 'read', 'update', 'delete'):
            with self.subTest(handler=handler):
                spec = {'type': 'AWS::S3::BucketPolicy', 'handler': handler,
                        'action': 's3:GetBucketPolicy', 'schema': {}}
                requests = operation_requests(spec, self.service)
                self.assertEqual([arn], [request[1] for request in requests])
                policy = [{'Effect': 'Allow', 'Action': spec['action'], 'Resource': arn}]
                self.assertEqual('Allow', evaluate(spec, self.service, policy)[1])
                policy.append({'Effect': 'Deny', 'Action': spec['action'], 'Resource': arn})
                self.assertEqual('Deny', evaluate(spec, self.service, policy)[1])

    def test_unknown_native_handler_does_not_assume_a_bucket(self):
        spec = {'type': 'AWS::S3::Unknown', 'handler': 'read',
                'action': 's3:GetBucketPolicy', 'schema': {}}
        policy = [{'Effect': 'Allow', 'Action': '*', 'Resource': '*'}]
        self.assertNotEqual('Allow', evaluate(spec, self.service, policy)[1])
