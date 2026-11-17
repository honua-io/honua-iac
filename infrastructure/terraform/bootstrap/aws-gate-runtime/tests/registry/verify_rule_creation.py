"""Check new-rule and existing-group authorization against rendered policies."""
from pathlib import Path
import sys

from audit import rendered_statements
from iam import decision
from verify_tags import workload_boundary

BASE = 'arn:aws:ec2:us-east-1:000000000002:'
REGION = {'aws:RequestedRegion': 'us-east-1'}
OWNED = {**REGION, 'aws:ResourceTag/HonuaGate': 'true'}
ACTIONS = ['ec2:AuthorizeSecurityGroupIngress', 'ec2:AuthorizeSecurityGroupEgress']


def scenarios():
    yield BASE + 'security-group/sg-owned', OWNED, 'Allow'
    yield BASE + 'security-group/sg-foreign', REGION, 'Deny'
    yield BASE + 'security-group-rule/sgr-new', REGION, 'Allow'
    for kind in ['security-group/sg-owned', 'security-group-rule/sgr-new']:
        arn = BASE + kind
        yield arn.replace('000000000002', '000000000003'), OWNED, 'Deny'
        yield arn.replace('us-east-1', 'us-west-2'), OWNED, 'Deny'
        yield arn, {**OWNED, 'aws:RequestedRegion': 'us-west-2'}, 'Deny'
    yield BASE + 'vpc/vpc-owned', OWNED, 'Deny'


def verify(path):
    statements = rendered_statements(path)
    boundary = workload_boundary(path)
    checks = 0
    for action in ACTIONS:
        for arn, context, expected in scenarios():
            actual = decision(statements, (action, arn, context))
            if actual != expected:
                raise AssertionError((action, arn, context, expected, actual))
            checks += 1
        if decision(boundary, (action, BASE + 'security-group-rule/sgr-new', REGION)) != 'Deny':
            raise AssertionError('Workload boundary must reject unowned rule allocation')
        checks += 1
    print(f'{checks} rendered-policy security-group rule scenarios passed')


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
