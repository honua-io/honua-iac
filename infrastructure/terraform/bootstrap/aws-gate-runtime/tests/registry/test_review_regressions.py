"""Missing request context and authorization resources must not produce allows."""
import json
from pathlib import Path
import unittest

from audit import evaluate
from requests import request_for


class ReviewRegressions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.services = json.loads(Path(__file__).with_name('launch-stack.json').read_text())['authorization']

    def spec(self, kind, action, **extra):
        return {'type': kind, 'handler': 'create', 'action': action, 'schema': {}, **extra}

    def test_role_creation_does_not_invent_a_boundary(self):
        spec = self.spec('AWS::IAM::Role', 'iam:CreateRole')
        policy = [{'Effect': 'Allow', 'Action': spec['action'], 'Resource': '*',
                   'Condition': {'ArnEquals': {'iam:PermissionsBoundary':
                                 'arn:aws:iam::000000000002:policy/mock'}}}]
        self.assertEqual('ImplicitDeny', evaluate(spec, self.services['iam'], policy)[1])

    def test_restore_target_has_no_existing_ownership_tags(self):
        for action in ['RestoreDBInstanceFromDBSnapshot', 'RestoreDBInstanceToPointInTime']:
            with self.subTest(action=action):
                request = request_for(self.spec('AWS::RDS::DBInstance', 'rds:' + action), self.services['rds'])
                self.assertNotIn('aws:ResourceTag/HonuaGate', request[2])
                self.assertNotIn('aws:ResourceTag/aws:cloudformation:stack-name', request[2])

    def test_endpoint_only_permission_cannot_authorize_endpoint_creation(self):
        spec = self.spec('AWS::EC2::VPCEndpoint', 'ec2:CreateVpcEndpoint')
        policy = [{'Effect': 'Allow', 'Action': spec['action'],
                   'Resource': 'arn:aws:ec2:*:*:vpc-endpoint/*'}]
        self.assertNotEqual('Allow', evaluate(spec, self.services['ec2'], policy)[1])

    def test_unknown_multi_resource_mapping_cannot_select_just_one_resource(self):
        spec = self.spec('AWS::RDS::DBInstance', 'rds:RestoreDBInstanceFromDBSnapshot')
        policy = [{'Effect': 'Allow', 'Action': spec['action'], 'Resource': '*'}]
        self.assertNotEqual('Allow', evaluate(spec, self.services['rds'], policy)[1])

    def test_cloudfront_service_linked_role_does_not_assume_ecs(self):
        spec = self.spec('AWS::CloudFront::VpcOrigin', 'iam:CreateServiceLinkedRole')
        policy = [{'Effect': 'Allow', 'Action': spec['action'], 'Resource': '*',
                   'Condition': {'StringEquals': {'iam:AWSServiceName': 'ecs.amazonaws.com'}}}]
        self.assertNotEqual('Allow', evaluate(spec, self.services['iam'], policy)[1])

    def test_ecs_task_role_is_not_passed_to_lambda(self):
        spec = self.spec('AWS::ECS::TaskDefinition', 'iam:PassRole')
        policy = [{'Effect': 'Allow', 'Action': spec['action'], 'Resource': '*',
                   'Condition': {'StringEquals': {'iam:PassedToService': 'lambda.amazonaws.com'}}}]
        self.assertEqual('ImplicitDeny', evaluate(spec, self.services['iam'], policy)[1])
        policy[0]['Condition']['StringEquals']['iam:PassedToService'] = 'ecs-tasks.amazonaws.com'
        self.assertEqual('Allow', evaluate(spec, self.services['iam'], policy)[1])

    def test_lambda_role_retains_its_service_identity(self):
        spec = self.spec('AWS::Lambda::Function', 'iam:PassRole')
        request = request_for(spec, self.services['iam'])
        self.assertEqual('lambda.amazonaws.com', request[2]['iam:PassedToService'])

    def test_unmapped_passed_role_service_stays_unresolved(self):
        spec = self.spec('AWS::Events::Unknown', 'iam:PassRole')
        policy = [{'Effect': 'Allow', 'Action': '*', 'Resource': '*'}]
        self.assertNotEqual('Allow', evaluate(spec, self.services['iam'], policy)[1])

    def test_event_rule_role_is_passed_to_events_not_its_ecs_target(self):
        spec = self.spec('AWS::Events::Rule', 'iam:PassRole')
        action, resource, context = request_for(spec, self.services['iam'])
        self.assertEqual('events.amazonaws.com', context['iam:PassedToService'])
        policy = [{'Effect': 'Allow', 'Action': action, 'Resource': resource,
                   'Condition': {'StringEquals': {'iam:PassedToService': 'ecs-tasks.amazonaws.com'}}}]
        self.assertEqual('ImplicitDeny', evaluate(spec, self.services['iam'], policy)[1])
        policy[0]['Condition']['StringEquals']['iam:PassedToService'] = 'events.amazonaws.com'
        self.assertEqual('Allow', evaluate(spec, self.services['iam'], policy)[1])
        policy.append({'Effect': 'Deny', 'Action': action, 'Resource': resource})
        self.assertEqual('Deny', evaluate(spec, self.services['iam'], policy)[1])
        self.assertEqual('ImplicitDeny', evaluate(spec, self.services['iam'], [])[1])
