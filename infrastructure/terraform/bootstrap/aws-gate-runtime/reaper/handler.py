"""Delete expired, unprotected top-level gate stacks in the gate region."""
import datetime as dt
import logging
import os

LOG = logging.getLogger(__name__)
LOG.setLevel(logging.INFO)
MAX_AGE = dt.timedelta(hours=24)


def eligible(stack, now):
    return (stack['StackName'].startswith('honua-gate-')
            and now - stack['CreationTime'] > MAX_AGE
            and not stack.get('ParentId')
            and stack['StackStatus'] not in ('DELETE_COMPLETE', 'DELETE_IN_PROGRESS')
            and not stack.get('EnableTerminationProtection', False)
            and not any(tag['Key'] == 'keep' for tag in stack.get('Tags', [])))


def reap(client, now, service_role):
    deleted = 0
    failures = 0
    for page in client.get_paginator('list_stacks').paginate():
        for summary in page['StackSummaries']:
            if not eligible(summary, now):
                continue
            try:
                stack = client.describe_stacks(StackName=summary['StackId'])['Stacks'][0]
                if eligible(stack, now):
                    client.delete_stack(StackName=stack['StackId'], RoleARN=service_role)
                    deleted += 1
            except Exception:
                failures += 1
                LOG.exception('Gate stack cleanup failed')
    if failures:
        raise RuntimeError(f'Cleanup failed for {failures} stack(s)')
    return {'deleted': deleted}


def lambda_handler(event, context):
    import boto3
    return reap(boto3.client('cloudformation', region_name='us-east-1'),
                dt.datetime.now(dt.timezone.utc), os.environ['SERVICE_ROLE_ARN'])
