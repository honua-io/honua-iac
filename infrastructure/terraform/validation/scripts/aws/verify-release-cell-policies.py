#!/usr/bin/env python3
"""Evaluate Terraform-rendered policies in AWS IAM (read-only, never mutate resources).

Input is `terraform test -json -verbose` from bootstrap/aws-release-cells.
Expected decisions below follow the isolation contract, not current policy output.
AWS credentials need iam:SimulateCustomPolicy. No assume-role or resource deletion.
"""
from concurrent.futures import ThreadPoolExecutor
from fnmatch import fnmatchcase
import argparse
import json
import subprocess
import time
from pathlib import Path


def aws(payload):
    for delay in [0, 10, 30, 60, 120, 60]:
        if delay:
            time.sleep(delay)
        result = subprocess.run(
            ['aws', 'iam', 'simulate-custom-policy', '--cli-input-json', json.dumps(payload), '--output', 'json'],
            text=True, capture_output=True,
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
        if not any(s in result.stderr.lower() for s in ['could not connect', 'could not resolve', 'connection reset', 'timeout', 'timed out', 'throttl']):
            raise RuntimeError(result.stderr)
    raise RuntimeError(result.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('terraform_test_jsonl', type=Path)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    output = None
    for line in args.terraform_test_jsonl.read_text().splitlines():
        event = json.loads(line)
        if event.get('type') == 'test_plan' and event.get('@testrun') == 'policies':
            output = {k: v['after'] for k, v in event['test_plan']['output_changes'].items() if 'after' in v}
    if output is None:
        raise ValueError('Missing policies test plan; run terraform test -json -verbose first')
    account = '123456789012'  # mock fixture account; no resource with this ARN need exist
    function = f'arn:aws:lambda:us-east-1:{account}:function:honuarfixture-it'
    role = f'arn:aws:iam::{account}:role/honuarfixture-it'
    boundary = f'arn:aws:iam::{account}:policy/honua-release-cell-workload-boundary'
    tags = {'aws:ResourceTag/Owner': 'release-cell', 'aws:ResourceTag/ValidationRunId': 'gha-208-aws-ecs'}
    request = {'aws:RequestTag/Owner': 'release-cell', 'aws:RequestTag/ValidationRunId': 'gha-208-aws-ecs'}
    cases = []
    def case(lane, name, action, resource, expected, context=None):
        cases.append((lane, name, action, resource, expected, {'aws:RequestedRegion': 'us-east-1', **(context or {})}))
    for lane in ['provision', 'reaper', 'mirror', 'runtime']:
        for environment in ['standing', 'cert', 'demo']:
            for action in ['lambda:DeleteFunction', 'lambda:UpdateFunctionCode']:
                case(lane, f'protect-{environment}-{action}', action, function, 'explicitDeny', {**tags, 'aws:ResourceTag/Environment': environment})
        case(lane, 'outside-region', 'lambda:UpdateFunctionCode', function.replace('us-east-1', 'us-west-2'), 'explicitDeny', {**tags, 'aws:RequestedRegion': 'us-west-2'})
        case(lane, 'no-role-chaining', 'sts:AssumeRole', role, 'explicitDeny')
        case(lane, 'no-boundary-removal', 'iam:DeleteRolePermissionsBoundary', role, 'explicitDeny')
        case(lane, 'no-boundary-replacement', 'iam:PutRolePermissionsBoundary', role, 'explicitDeny', {'iam:PermissionsBoundary': f'arn:aws:iam::{account}:policy/other'})
        case(lane, 'no-safety-tag-removal', 'lambda:UntagResource', function, 'explicitDeny', {**tags, 'aws:TagKeys': ['Owner']})
    case('provision', 'bounded-role-create', 'iam:CreateRole', role, 'allowed', {**request, 'iam:PermissionsBoundary': boundary})
    case('provision', 'unbounded-role-create', 'iam:CreateRole', role, 'explicitDeny', request)
    case('provision', 'missing-owner', 'iam:CreateRole', role, 'implicitDeny', {'aws:RequestTag/ValidationRunId': 'gha-208-aws-ecs', 'iam:PermissionsBoundary': boundary})
    case('provision', 'missing-run', 'iam:CreateRole', role, 'implicitDeny', {'aws:RequestTag/Owner': 'release-cell', 'iam:PermissionsBoundary': boundary})
    case('provision', 'update-own-cell', 'lambda:UpdateFunctionCode', function, 'allowed', tags)
    case('provision', 'no-teardown', 'lambda:DeleteFunction', function, 'implicitDeny', tags)
    case('provision', 'no-mirror-push', 'ecr:PutImage', f'arn:aws:ecr:us-east-1:{account}:repository/honua-server', 'implicitDeny')
    case('reaper', 'delete-own-cell', 'lambda:DeleteFunction', function, 'allowed', tags)
    case('reaper', 'unowned-resource', 'lambda:DeleteFunction', function, 'implicitDeny', {'aws:ResourceTag/ValidationRunId': 'gha-208-aws-ecs'})
    case('reaper', 'no-run-resource', 'lambda:DeleteFunction', function, 'implicitDeny', {'aws:ResourceTag/Owner': 'release-cell'})
    case('reaper', 'outside-namespace', 'lambda:DeleteFunction', function.replace('honuarfixture', 'customer-production'), 'implicitDeny', tags)
    case('reaper', 'no-create', 'lambda:CreateFunction', function, 'implicitDeny', request)
    case('mirror', 'push-exact-repository', 'ecr:PutImage', f'arn:aws:ecr:us-east-1:{account}:repository/honua-server', 'allowed')
    case('mirror', 'no-other-repository', 'ecr:PutImage', f'arn:aws:ecr:us-east-1:{account}:repository/other', 'implicitDeny')
    case('mirror', 'no-delete-mirror', 'ecr:DeleteRepository', f'arn:aws:ecr:us-east-1:{account}:repository/honua-server', 'implicitDeny')
    case('runtime', 'broad-inline-cannot-create-user', 'iam:CreateUser', f'arn:aws:iam::{account}:user/escalation', 'explicitDeny')
    key = f'arn:aws:kms:us-east-1:{account}:key/fixture-208'
    for lane, action in [('provision', 'kms:EnableKeyRotation'), ('reaper', 'kms:DescribeKey'), ('reaper', 'kms:ScheduleKeyDeletion'), ('runtime', 'kms:Decrypt')]:
        case(lane, 'owned-key-' + action, action, key, 'allowed', tags)
        case(lane, 'unowned-key-' + action, action, key, 'implicitDeny')
    case('provision', 'tagged-key-create', 'kms:CreateKey', '*', 'allowed', request)
    case('provision', 'untagged-key-create', 'kms:CreateKey', '*', 'implicitDeny')
    api = 'arn:aws:apigateway:us-east-1::/apis'
    case('provision', 'tagged-api-create', 'apigateway:POST', api, 'allowed', request)
    case('provision', 'owned-api-update', 'apigateway:PATCH', api + '/fixture', 'allowed', tags)
    case('reaper', 'owned-api-delete', 'apigateway:DELETE', api + '/fixture', 'allowed', tags)
    scaling = f'arn:aws:application-autoscaling:us-east-1:{account}:scalable-target/fixture'
    case('provision', 'tagged-scaling-create', 'application-autoscaling:RegisterScalableTarget', scaling, 'allowed', request)
    case('reaper', 'owned-scaling-delete', 'application-autoscaling:DeregisterScalableTarget', scaling, 'allowed', tags)
    eni = f'arn:aws:ec2:us-east-1:{account}:network-interface/eni-0123456789abcdef0'
    for action in ['ec2:CreateNetworkInterface', 'ec2:DeleteNetworkInterface', 'ec2:AssignPrivateIpAddresses', 'ec2:UnassignPrivateIpAddresses']:
        case('runtime', 'approved-vpc-' + action, action, eni, 'allowed', {'ec2:Vpc': f'arn:aws:ec2:us-east-1:{account}:vpc/vpc-0123456789abcdef0'})
        case('runtime', 'other-vpc-' + action, action, eni, 'implicitDeny', {'ec2:Vpc': f'arn:aws:ec2:us-east-1:{account}:vpc/vpc-other'})
    for action in ['bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream']:
        case('runtime', 'approved-model-' + action, action, 'arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0', 'allowed')
        case('runtime', 'other-model-' + action, action, 'arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0', 'implicitDeny')
    for prefix in ['honuarfixture', 'honuanfixture']:
        case('runtime', 'submit-' + prefix, 'batch:SubmitJob', f'arn:aws:batch:us-east-1:{account}:job-queue/{prefix}-gp', 'allowed')
        case('runtime', 'logs-' + prefix, 'logs:PutLogEvents', f'arn:aws:logs:us-east-1:{account}:log-group:/aws/lambda/{prefix}-honua:*', 'allowed')
    for log_path in ['/honua/honuarfixture', '/aws/batch/honuarfixture-gp']:
        case('runtime', 'logs-' + log_path, 'logs:PutLogEvents', f'arn:aws:logs:us-east-1:{account}:log-group:{log_path}:*', 'allowed')
    case('runtime', 'no-other-queue', 'batch:SubmitJob', f'arn:aws:batch:us-east-1:{account}:job-queue/customer-production', 'implicitDeny')
    case('runtime', 'invoke-cell-handler', 'lambda:InvokeFunction', function, 'allowed')
    case('runtime', 'no-other-handler', 'lambda:InvokeFunction', function.replace('honuarfixture', 'customer-production'), 'implicitDeny')
    case('runtime', 'no-other-logs', 'logs:PutLogEvents', f'arn:aws:logs:us-east-1:{account}:log-group:/aws/lambda/customer-production:*', 'implicitDeny')
    case('runtime', 'no-standing-logs', 'logs:PutLogEvents', f'arn:aws:logs:us-east-1:{account}:log-group:/aws/lambda/honuarfixture:*', 'explicitDeny', {'aws:ResourceTag/Environment': 'standing'})
    # IAM simulation accepts the log group's authorization ARN ending in :*.
    # A concrete :log-stream: ARN returns implicitDeny even under isolated
    # Allow * (AWS simulator limitation, reproduced 2026-09-29). Independently
    # assert that the real stream ARNs also match the rendered resource ceiling.
    runtime = json.loads(output['runtime_boundary'])
    log_resources = [resource for statement in runtime['Statement']
                     if statement.get('Sid') == 'CellRuntime'
                     for resource in statement['Resource'] if ':logs:' in resource]
    for path in ['/aws/lambda/honuarfixture-honua', '/aws/lambda/honuanfixture-honua', '/honua/honuarfixture', '/aws/batch/honuarfixture-gp']:
        stream = f'arn:aws:logs:us-east-1:{account}:log-group:{path}:log-stream:fixture'
        assert any(fnmatchcase(stream, pattern) for pattern in log_resources), stream
    assert not any(fnmatchcase(f'arn:aws:logs:us-east-1:{account}:log-group:/aws/lambda/customer-production:log-stream:fixture', pattern) for pattern in log_resources)
    def evaluate(fixture):
        lane, name, action, resource, expected, context = fixture
        entries = [{'ContextKeyName': k, 'ContextKeyValues': v if isinstance(v, list) else [v], 'ContextKeyType': 'stringList' if isinstance(v, list) else 'string'} for k, v in context.items()]
        resources = [resource]
        # CreateNetworkInterface authorizes three resources. ec2:Vpc is available
        # on the subnet/security-group checks, not the new interface check.
        if action == 'ec2:CreateNetworkInterface':
            resources += [f'arn:aws:ec2:us-east-1:{account}:subnet/subnet-0123456789abcdef0', f'arn:aws:ec2:us-east-1:{account}:security-group/sg-0123456789abcdef0']
        payload = dict(ActionNames=[action], ResourceArns=resources, ContextEntries=entries)
        if lane == 'runtime':
            payload['PolicyInputList'] = [json.dumps({'Version': '2012-10-17', 'Statement': [{'Effect': 'Allow', 'Action': '*', 'Resource': '*'}]})]
            payload['PermissionsBoundaryPolicyInputList'] = [output['runtime_boundary']]
        else:
            payload['PolicyInputList'] = [output['policies'][lane]]
        response = aws(payload)['EvaluationResults']
        actual = response[0]['EvalDecision']
        receipt = dict(lane=lane, case=name, action=action, resource=resource, expected=expected, actual=actual)
        print(f'{lane}/{name}: {actual}', flush=True)
        return receipt
    with ThreadPoolExecutor(max_workers=4) as pool:
        receipts = list(pool.map(evaluate, cases))
    args.receipt.write_text(json.dumps({'source': str(args.terraform_test_jsonl), 'cases': receipts}, indent=2) + '\n')
    failures = [r for r in receipts if r['expected'] != r['actual']]
    if failures:
        raise AssertionError(json.dumps(failures, indent=2))
    print(f'PASS: {len(receipts)} AWS IAM decisions matched independent expectations')


if __name__ == '__main__':
    main()
