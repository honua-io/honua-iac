#!/usr/bin/env python3
"""Read-only AWS IAM verification of the Terraform mock-apply Bedrock policies."""
import argparse
import json
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('terraform_test_jsonl')
p.add_argument('--receipt', required=True)
a = p.parse_args()
policies = {}
for line in open(a.terraform_test_jsonl):
    event = json.loads(line)
    if event.get('type') != 'test_state':
        continue
    for resource in event['test_state']['root_module']['resources']:
        if resource['type'] == 'aws_iam_role_policy' and 'bedrock_invoke' in resource['name']:
            policies[event['@testrun']] = resource['values']['policy']
if not policies:
    raise ValueError('No rendered Bedrock policy; use terraform test -json -verbose')
results = []
for run, policy in policies.items():
    targets = [
        ('bedrock:InvokeModel', 'arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0', 'allowed'),
        ('bedrock:InvokeModelWithResponseStream', 'arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0', 'allowed'),
        ('bedrock:InvokeModel', 'arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0', 'implicitDeny'),
        ('bedrock:CreateModelCustomizationJob', '*', 'implicitDeny'),
    ]
    for action, resource, expected in targets:
        payload = dict(PolicyInputList=[policy], ActionNames=[action], ResourceArns=[resource])
        for delay in [0, 10, 30, 60, 120, 60]:
            if delay:
                time.sleep(delay)
            process = subprocess.run(['aws', 'iam', 'simulate-custom-policy', '--cli-input-json', json.dumps(payload)], text=True, capture_output=True)
            if process.returncode == 0:
                break
            if not any(x in process.stderr.lower() for x in ['could not connect', 'could not resolve', 'connection reset', 'timeout', 'timed out', 'throttl']):
                raise RuntimeError(process.stderr)
        if process.returncode:
            raise RuntimeError(process.stderr)
        actual = json.loads(process.stdout)['EvaluationResults'][0]['EvalDecision']
        results.append(dict(run=run, action=action, resource=resource, expected=expected, actual=actual))
        assert actual == expected, results[-1]
with open(a.receipt, 'w') as f:
    json.dump({'cases': results}, f, indent=2)
print(f'PASS: {len(results)} AWS Bedrock IAM decisions')
