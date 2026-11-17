"""Sync the gate IdP client's callback URLs with the live gate stacks.

The gate lane invokes this function after a gate stack reaches a complete state.
It registers only the OidcCallbackUrl output of live honua-gate-* stacks whose
host is the domain of a CloudFront distribution that the same stack owns in this
account, plus the static Terraform callbacks.
"""
import logging
import os
import re

LOG = logging.getLogger(__name__)
LOG.setLevel(logging.INFO)
MAX_CALLBACKS = 100
CALLBACK = re.compile(r'^https://([a-z0-9]+\.cloudfront\.net)/admin/auth/callback$')
LIVE = ('CREATE_COMPLETE', 'UPDATE_COMPLETE', 'UPDATE_ROLLBACK_COMPLETE',
        'UPDATE_COMPLETE_CLEANUP_IN_PROGRESS', 'UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS',
        'UPDATE_IN_PROGRESS', 'UPDATE_ROLLBACK_IN_PROGRESS', 'UPDATE_ROLLBACK_FAILED',
        'UPDATE_FAILED', 'IMPORT_COMPLETE', 'IMPORT_ROLLBACK_COMPLETE')
# Every field UpdateUserPoolClient accepts; omitted fields reset to defaults, so all are copied.
UPDATABLE = ('ClientName', 'RefreshTokenValidity', 'AccessTokenValidity', 'IdTokenValidity',
             'TokenValidityUnits', 'ReadAttributes', 'WriteAttributes', 'ExplicitAuthFlows',
             'SupportedIdentityProviders', 'LogoutURLs', 'DefaultRedirectURI',
             'AllowedOAuthFlows', 'AllowedOAuthScopes', 'AllowedOAuthFlowsUserPoolClient',
             'AnalyticsConfiguration', 'PreventUserExistenceErrors', 'EnableTokenRevocation',
             'EnablePropagateAdditionalUserContextData', 'AuthSessionValidity',
             'RefreshTokenRotation')


def own_domains(cf, cloudfront, stack_id):
    """Domain names of the CloudFront distributions this stack created."""
    domains = set()
    for page in cf.get_paginator('list_stack_resources').paginate(StackName=stack_id):
        for resource in page['StackResourceSummaries']:
            if resource['ResourceType'] == 'AWS::CloudFront::Distribution' and resource.get('PhysicalResourceId'):
                distribution = cloudfront.get_distribution(Id=resource['PhysicalResourceId'])
                domains.add(distribution['Distribution']['DomainName'])
    return domains


def stack_callbacks(cf, cloudfront):
    """Callback outputs of live top-level gate stacks, newest first."""
    found = []
    for page in cf.get_paginator('list_stacks').paginate(StackStatusFilter=list(LIVE)):
        for summary in page['StackSummaries']:
            if not summary['StackName'].startswith('honua-gate-') or summary.get('ParentId'):
                continue
            stack = cf.describe_stacks(StackName=summary['StackId'])['Stacks'][0]
            url = next((o['OutputValue'] for o in stack.get('Outputs', [])
                        if o['OutputKey'] == 'OidcCallbackUrl'), None)
            match = CALLBACK.match(url or '')
            if match and match.group(1) in own_domains(cf, cloudfront, stack['StackId']):
                found.append((stack['CreationTime'], url))
            elif url:
                LOG.warning('Skipped a callback not on the stack\'s own distribution: %s', stack['StackName'])
    return [url for _, url in sorted(found, reverse=True)]


def desired_callbacks(static, live):
    callbacks = sorted(set(static))
    for url in live:
        if len(callbacks) >= MAX_CALLBACKS:
            LOG.warning('Callback limit reached; older gate stacks were not registered')
            break
        if url not in callbacks:
            callbacks.append(url)
    return callbacks


def sync(clients, client_ref, static):
    """clients is (cloudformation, cloudfront, cognito-idp); client_ref names the pool client."""
    cf, cloudfront, idp = clients
    client = idp.describe_user_pool_client(**client_ref)['UserPoolClient']
    callbacks = desired_callbacks(static, stack_callbacks(cf, cloudfront))
    if sorted(client.get('CallbackURLs', [])) == sorted(callbacks):
        return {'changed': False, 'callbacks': len(callbacks)}
    update = {key: client[key] for key in UPDATABLE if key in client}
    if update.get('DefaultRedirectURI') not in (None, *callbacks):
        update.pop('DefaultRedirectURI')
    idp.update_user_pool_client(**client_ref, CallbackURLs=callbacks, **update)
    return {'changed': True, 'callbacks': len(callbacks)}


def lambda_handler(event, context):
    import boto3
    return sync((boto3.client('cloudformation', region_name='us-east-1'),
                 boto3.client('cloudfront'),
                 boto3.client('cognito-idp', region_name='us-east-1')),
                {'UserPoolId': os.environ['USER_POOL_ID'], 'ClientId': os.environ['CLIENT_ID']},
                [url for url in os.environ.get('STATIC_CALLBACKS', '').split(',') if url])
