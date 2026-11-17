"""Native resource handlers select endpoints, not unrelated access-point variants."""
import json
from pathlib import Path
import unittest

from audit import evaluate
from operations import operation_requests


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
