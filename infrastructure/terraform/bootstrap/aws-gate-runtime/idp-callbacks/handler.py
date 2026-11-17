"""Register each live gate stack's CloudFront sign-in callback on the gate IdP client.

Cognito accepts only exact callback URLs, so every gate install would otherwise
need a Terraform apply. The lane may invoke this function but passes nothing:
the URLs come only from live honua-gate-* stacks whose OidcCallbackUrl output is
the default hostname of a CloudFront distribution the same stack owns.
"""
import json
import logging
import os
import re
from typing import Any, NamedTuple

LOG = logging.getLogger(__name__)
LOG.setLevel(logging.INFO)
MAX_CALLBACKS = 100
CALLBACK = re.compile(r'^https://([a-z0-9]+\.cloudfront\.net)/admin/auth/callback$')
# Stacks whose outputs exist and whose resources are still in place.
LIVE_STATUSES = [
    'CREATE_COMPLETE', 'UPDATE_IN_PROGRESS', 'UPDATE_COMPLETE_CLEANUP_IN_PROGRESS', 'UPDATE_COMPLETE',
    'UPDATE_ROLLBACK_IN_PROGRESS', 'UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS', 'UPDATE_ROLLBACK_COMPLETE',
    'UPDATE_ROLLBACK_FAILED', 'IMPORT_COMPLETE', 'IMPORT_ROLLBACK_COMPLETE',
]
# DescribeUserPoolClient fields that UpdateUserPoolClient does not accept. Every other field is sent back
# unchanged, because UpdateUserPoolClient resets omitted settings to their defaults.
READ_ONLY = ('ClientSecret', 'CreationDate', 'LastModifiedDate')


class Clients(NamedTuple):
    cloudformation: Any
    cloudfront: Any
    cognito: Any


class Target(NamedTuple):
    pool_id: str
    client_id: str
    static_urls: list


def stack_callback(cf, cloudfront, stack):
    url = next((o['OutputValue'] for o in stack.get('Outputs', []) if o['OutputKey'] == 'OidcCallbackUrl'), '')
    match = CALLBACK.match(url)
    if not match:
        return None
    owned = set()
    for page in cf.get_paginator('list_stack_resources').paginate(StackName=stack['StackId']):
        for resource in page['StackResourceSummaries']:
            if resource['ResourceType'] == 'AWS::CloudFront::Distribution' and resource.get('PhysicalResourceId'):
                owned.add(cloudfront.get_distribution(Id=resource['PhysicalResourceId'])['Distribution']['DomainName'])
    if match.group(1) not in owned:
        LOG.warning('Skipping %s: its callback host is not a distribution the stack owns', stack['StackName'])
        return None
    return url


def gate_callbacks(cf, cloudfront):
    urls = set()
    for page in cf.get_paginator('list_stacks').paginate(StackStatusFilter=LIVE_STATUSES):
        for summary in page['StackSummaries']:
            if not summary['StackName'].startswith('honua-gate-') or summary.get('ParentId'):
                continue
            stack = cf.describe_stacks(StackName=summary['StackId'])['Stacks'][0]
            url = stack_callback(cf, cloudfront, stack)
            if url:
                urls.add(url)
    return urls


def sync(clients, target):
    # Any lookup failure propagates before the write, so a partial view never drops a live stack's callback.
    desired = sorted(set(target.static_urls) | gate_callbacks(clients.cloudformation, clients.cloudfront))
    if len(desired) > MAX_CALLBACKS:
        raise RuntimeError(f'{len(desired)} callbacks exceed the Cognito limit of {MAX_CALLBACKS}; delete gate stacks first')
    client = clients.cognito.describe_user_pool_client(UserPoolId=target.pool_id, ClientId=target.client_id)['UserPoolClient']
    default = client.get('DefaultRedirectURI')
    if default and default not in desired:
        raise RuntimeError('DefaultRedirectURI is not among the synchronized callbacks; refusing to update')
    current = sorted(client.get('CallbackURLs', []))
    result = {'callbacks': len(desired), 'changed': desired != current,
              'added': sorted(set(desired) - set(current)), 'removed': sorted(set(current) - set(desired))}
    if result['changed']:
        update = {key: value for key, value in client.items() if key not in READ_ONLY}
        clients.cognito.update_user_pool_client(**(update | {'CallbackURLs': desired}))
    LOG.info('Gate IdP callbacks: %s', json.dumps(result))
    return result


def lambda_handler(event, context):
    """The event is ignored: callers cannot choose which URLs are registered."""
    import boto3
    clients = Clients(boto3.client('cloudformation', region_name='us-east-1'), boto3.client('cloudfront'),
                      boto3.client('cognito-idp', region_name='us-east-1'))
    target = Target(os.environ['USER_POOL_ID'], os.environ['CLIENT_ID'], json.loads(os.environ['STATIC_CALLBACK_URLS']))
    return sync(clients, target)
