"""Exercise first-tagging decisions against the actual rendered Terraform policies."""
import json
from pathlib import Path
import sys

from audit import rendered_statements
from iam import decision

TARGETS = {
    'cloudwatch:TagResource': ['arn:aws:cloudwatch:us-east-1:000000000002:alarm:honua-gate-test'],
    'lambda:TagResource': ['arn:aws:lambda:us-east-1:000000000002:function:honua-gate-test'],
    'logs:TagResource': [
        'arn:aws:logs:us-east-1:000000000002:log-group:/honua/honua-gate-test/audit',
        'arn:aws:logs:us-east-1:000000000002:log-group:/aws/lambda/honua-gate-test',
        'arn:aws:logs:us-east-1:000000000002:log-group:aws-waf-logs-honua-gate-test',
    ],
}
CONTEXT = {'aws:RequestedRegion': 'us-east-1', 'aws:RequestTag/HonuaGate': 'true'}


def scenarios(arn):
    yield arn, CONTEXT, 'Allow'
    yield arn, {'aws:RequestedRegion': 'us-east-1', 'aws:ResourceTag/HonuaGate': 'true'}, 'Allow'
    for original, replacement in [('honua-gate-test', 'production'),
                                  ('000000000002', '000000000003'), ('us-east-1', 'us-west-2')]:
        yield arn.replace(original, replacement), CONTEXT, 'Deny'
    yield arn, {'aws:RequestedRegion': 'us-east-1'}, 'Deny'
    yield arn, {**CONTEXT, 'aws:RequestTag/HonuaGate': 'false'}, 'Deny'
    yield arn, {**CONTEXT, 'aws:RequestedRegion': 'us-west-2'}, 'Deny'


def workload_boundary(path):
    for line in path.read_text().splitlines():
        event = json.loads(line)
        if event.get('@testrun') != 'shared_account_policy_quotas_with_deployment_sized_inputs':
            continue
        for resource in event.get('test_plan', {}).get('resource_changes', []):
            if resource['address'] == 'aws_iam_policy.workload_boundary':
                return json.loads(resource['change']['after']['policy'])['Statement']
    raise ValueError('Rendered workload boundary is required')


def verify(path):
    statements = rendered_statements(path)
    boundary = workload_boundary(path)
    checks = 0
    for action, arns in TARGETS.items():
        for arn, context, expected in [case for arn in arns for case in scenarios(arn)]:
            actual = decision(statements, (action, arn, context))
            if actual != expected:
                raise AssertionError((action, arn, context, expected, actual))
            checks += 1
        for arn in arns:
            if decision(boundary, (action, arn, CONTEXT)) != 'Deny':
                raise AssertionError('Workload boundary must reject first tagging: ' + action)
            checks += 1
        for arn in [arn for other, arns in TARGETS.items() if other != action for arn in arns]:
            if decision(statements, (action, arn, CONTEXT)) != 'Deny':
                raise AssertionError('Tagging exception crossed its API resource fence: ' + action)
            checks += 1
    print(f'{checks} rendered-policy tagging scenarios passed')


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
