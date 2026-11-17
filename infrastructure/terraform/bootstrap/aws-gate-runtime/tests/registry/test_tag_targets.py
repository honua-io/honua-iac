"""Tag APIs authorize their supplied ARN, without inventing first-tag ownership."""
import json
from pathlib import Path
import unittest

from audit import evaluate
from operations import operation_requests
from requests import synthetic_arn

CASES = [
    ("AWS::CloudWatch::Alarm", "cloudwatch", "alarm", ("TagResource", "UntagResource", "ListTagsForResource")),
    ("AWS::CloudWatch::CompositeAlarm", "cloudwatch", "alarm", ("TagResource", "UntagResource", "ListTagsForResource")),
    ("AWS::Logs::LogGroup", "logs", "log-group", ("TagResource", "UntagResource", "ListTagsForResource")),
    ("AWS::Lambda::Function", "lambda", "function", ("TagResource", "UntagResource", "ListTags")),
    ('AWS::SSM::Parameter', 'ssm', 'parameter', ('AddTagsToResource', 'RemoveTagsFromResource', 'ListTagsForResource')),
    ('AWS::S3::Bucket', 's3', 'bucket', ('TagResource', 'UntagResource', 'ListTagsForResource')),
    ('AWS::CloudTrail::Trail', 'cloudtrail', 'trail', ('AddTags', 'RemoveTags', 'ListTags')),
    ('AWS::GuardDuty::Detector', 'guardduty', 'detector', ('TagResource', 'UntagResource', 'ListTagsForResource')),
    ('AWS::Route53::HealthCheck', 'route53', 'healthcheck', ('ChangeTagsForResource', 'ListTagsForResource')),
    ('AWS::Budgets::Budget', 'budgets', 'budget', ('TagResource', 'UntagResource', 'ListTagsForResource')),
    ('AWS::RDS::DBInstance', 'rds', 'db', ('AddTagsToResource', 'RemoveTagsFromResource', 'ListTagsForResource')),
    ('AWS::RDS::DBParameterGroup', 'rds', 'pg', ('AddTagsToResource', 'RemoveTagsFromResource', 'ListTagsForResource')),
    ('AWS::RDS::DBSubnetGroup', 'rds', 'subgrp', ('AddTagsToResource', 'RemoveTagsFromResource', 'ListTagsForResource')),
    ('AWS::CloudFront::VpcOrigin', 'cloudfront', 'vpcorigin', ('TagResource', 'UntagResource', 'ListTagsForResource')),
    ('AWS::CloudFront::Function', 'cloudfront', 'function', ('TagResource', 'UntagResource', 'ListTagsForResource')),
    ('AWS::CloudFront::Distribution', 'cloudfront', 'distribution', ('TagResource', 'UntagResource', 'ListTagsForResource')),
    ('AWS::ECS::Cluster', 'ecs', 'cluster', ('TagResource', 'UntagResource', 'ListTagsForResource')),
    ('AWS::ECS::Service', 'ecs', 'service', ('TagResource', 'UntagResource', 'ListTagsForResource')),
    ('AWS::ECS::TaskDefinition', 'ecs', 'task-definition', ('TagResource', 'UntagResource', 'ListTagsForResource')),
    ('AWS::Batch::ComputeEnvironment', 'batch', 'compute-environment', ('TagResource', 'UntagResource')),
    ('AWS::Batch::JobDefinition', 'batch', 'job-definition-revision', ('TagResource', 'UntagResource')),
    ('AWS::Batch::JobQueue', 'batch', 'job-queue', ('TagResource', 'UntagResource')),
    ('AWS::WAFv2::WebACL', 'wafv2', 'webacl', ('TagResource', 'UntagResource', 'ListTagsForResource')),
    ('AWS::Backup::BackupPlan', 'backup', 'backupPlan', ('TagResource', 'UntagResource', 'ListTags')),
    ('AWS::Backup::BackupVault', 'backup', 'backupVault', ('TagResource', 'UntagResource', 'ListTags')),
]


class TagTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.services = json.loads(Path(__file__).with_name('launch-stack.json').read_text())['authorization']

    def test_tag_api_uses_only_the_supplied_resource_type(self):
        cases = [(kind, service, target, action) for kind, service, target, actions in CASES for action in actions]
        for kind, service, target, action in cases:
            with self.subTest(kind=kind, action=action):
                spec = {'type': kind, 'handler': 'update', 'action': service + ':' + action, 'schema': {}}
                requests = operation_requests(spec, self.services[service])
                self.assertEqual(1, len(requests))
                resource = next(r for r in self.services[service]["Resources"] if r["Name"] == target)
                self.assertEqual(synthetic_arn(resource), requests[0][1])
                policy = [{'Effect': 'Allow', 'Action': spec['action'], 'Resource': requests[0][1]}]
                self.assertEqual('Allow', evaluate(spec, self.services[service], policy)[1])
                policy.append({'Effect': 'Deny', 'Action': spec['action'], 'Resource': requests[0][1]})
                self.assertEqual('Deny', evaluate(spec, self.services[service], policy)[1])

    def test_first_tagging_does_not_invent_existing_tags(self):
        for kind, service, _, actions in CASES:
            with self.subTest(kind=kind):
                spec = {'type': kind, 'handler': 'create', 'action': service + ':' + actions[0], 'schema': {}}
                request = operation_requests(spec, self.services[service])[0]
                self.assertNotIn('aws:ResourceTag/HonuaGate', request[2])
                self.assertNotIn('aws:ResourceTag/aws:cloudformation:stack-name', request[2])

    def test_ec2_tags_name_only_the_managed_resource(self):
        targets = {'VPCEndpoint': 'vpc-endpoint', 'SecurityGroup': 'security-group',
                   'Subnet': 'subnet', 'RouteTable': 'route-table', 'EIP': 'elastic-ip',
                   'NatGateway': 'natgateway', 'InternetGateway': 'internet-gateway',
                   'VPC': 'vpc', 'FlowLog': 'vpc-flow-log'}
        cases = [(kind, target, action) for kind, target in targets.items()
                 for action in ('CreateTags', 'DeleteTags')]
        for kind, target, action in cases:
            with self.subTest(kind=kind, action=action):
                spec = {'type': 'AWS::EC2::' + kind, 'handler': 'update',
                        'action': 'ec2:' + action, 'schema': {}}
                requests = operation_requests(spec, self.services['ec2'])
                self.assertEqual(1, len(requests))
                self.assertIn(':' + target + '/', requests[0][1])
                self.assertNotIn('ec2:CreateAction', requests[0][2])

    def test_ec2_first_tagging_checks_post_create_and_tag_on_create(self):
        spec = {'type': 'AWS::EC2::Subnet', 'handler': 'create',
                'action': 'ec2:CreateTags', 'schema': {}}
        requests = operation_requests(spec, self.services['ec2'])
        self.assertEqual(2, len(requests))
        self.assertEqual({None, 'CreateSubnet'}, {r[2].get('ec2:CreateAction') for r in requests})
        for request in requests:
            self.assertNotIn('aws:ResourceTag/HonuaGate', request[2])
        policy = [{'Effect': 'Allow', 'Action': 'ec2:CreateTags', 'Resource': '*',
                   'Condition': {'StringEquals': {'ec2:CreateAction': 'CreateSubnet'}}}]
        self.assertEqual('ImplicitDeny', evaluate(spec, self.services['ec2'], policy)[1])

    def test_unknown_tag_resource_type_stays_unresolved(self):
        spec = {'type': 'AWS::CloudWatch::Unknown', 'handler': 'update',
                'action': 'cloudwatch:TagResource', 'schema': {}}
        policy = [{'Effect': 'Allow', 'Action': '*', 'Resource': '*'}]
        self.assertNotEqual('Allow', evaluate(spec, self.services['cloudwatch'], policy)[1])
