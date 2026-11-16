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
    cf = boto3.client('cloudformation', region_name='us-east-1')
    result = reap(cf, dt.datetime.now(dt.timezone.utc), os.environ['SERVICE_ROLE_ARN'])
    result['orphans'] = reap_orphans(
        cf, boto3.client('iam'), boto3.client('kms', region_name='us-east-1'),
        dry_run=os.environ.get('ORPHAN_DRY_RUN', 'true').lower() != 'false')
    return result


GATE_TAG = 'HonuaGate'


def resource_tags(client, operation, field, **request):
    """Collect tags even when a service does not provide a paginator."""
    tags = []
    while True:
        page = getattr(client, operation)(**request)
        tags.extend(page[field])
        if not page.get('IsTruncated', page.get('Truncated', False)):
            return tags
        request['Marker'] = page['NextMarker'] if 'NextMarker' in page else page['Marker']


def role_owner(name, stacks):
    if not name.startswith('honua-gate-'):
        return None
    # IAM cannot carry reserved CloudFormation tags. Longest historical name
    # match protects similarly named, still-live stacks.
    return max((s for s in stacks if name == s or name.startswith(s + '-')),
               key=len, default=None)


def stack_is_gone(cf, name):
    try:
        stacks = cf.describe_stacks(StackName=name)['Stacks']
        return bool(stacks) and all(s['StackStatus'] == 'DELETE_COMPLETE' for s in stacks)
    except Exception as error:
        detail = getattr(error, 'response', {}).get('Error', {})
        if detail.get('Code') == 'ValidationError' and detail.get('Message') == (
                f'Stack with id {name} does not exist'):
            return True
        raise


def delete_role(iam, name):
    for page in iam.get_paginator('list_role_policies').paginate(RoleName=name):
        for policy in page['PolicyNames']:
            iam.delete_role_policy(RoleName=name, PolicyName=policy)
    for page in iam.get_paginator('list_attached_role_policies').paginate(RoleName=name):
        for policy in page['AttachedPolicies']:
            iam.detach_role_policy(RoleName=name, PolicyArn=policy['PolicyArn'])
    iam.delete_role(RoleName=name)


def orphan_role(cf, iam, role, stacks, dry_run):
    name = role['RoleName']
    owner = role_owner(name, stacks)
    if not owner or not stack_is_gone(cf, owner):
        return 0
    LOG.info('%s remove inline policies, detach managed policies and delete role %s (stack %s)',
             'Would' if dry_run else 'Will', name, owner)
    if not dry_run:
        delete_role(iam, name)
    return 1


def orphan_key(cf, kms, key, dry_run):
    key_id, owner = key
    metadata = kms.describe_key(KeyId=key_id)['KeyMetadata']
    if metadata['KeyManager'] != 'CUSTOMER' or metadata['KeyState'] in (
            'PendingDeletion', 'PendingReplicaDeletion'):
        return 0
    tags = resource_tags(kms, 'list_resource_tags', 'Tags', KeyId=key_id)
    if not any(tag['TagKey'] == GATE_TAG and tag['TagValue'] == 'true' for tag in tags):
        return 0
    if not stack_is_gone(cf, owner):
        return 0
    LOG.info('%s schedule key %s deletion in 7 days (stack %s)',
             'Would' if dry_run else 'Will', key_id, owner)
    if not dry_run:
        kms.schedule_key_deletion(KeyId=key_id, PendingWindowInDays=7)
    return 1


def stack_key_ids(cf, stack_id):
    pages = cf.get_paginator('list_stack_resources').paginate(StackName=stack_id)
    resources = (resource for page in pages for resource in page['StackResourceSummaries'])
    for resource in resources:
        if resource['ResourceType'] == 'AWS::KMS::Key' and resource.get('PhysicalResourceId'):
            yield resource['PhysicalResourceId']


def recorded_keys(cf, stacks):
    """Use physical IDs retained in deleted stack history, never guessed key names."""
    keys = {}
    for stack in stacks:
        if stack['StackStatus'] != 'DELETE_COMPLETE':
            continue
        keys.update((key_id, stack['StackName']) for key_id in stack_key_ids(cf, stack['StackId']))
    return keys.items()


def reap_orphans(cf, iam, kms, dry_run=True):
    stacks = [s for page in cf.get_paginator('list_stacks').paginate()
              for s in page['StackSummaries'] if s['StackName'].startswith('honua-gate-')]
    names = [s['StackName'] for s in stacks]
    result = {'roles': 0, 'keys': 0, 'dry_run': dry_run}
    failures = 0
    roles = (role for page in iam.get_paginator('list_roles').paginate() for role in page['Roles'])
    for field, resources, cleanup in (
            ('roles', roles, lambda role: orphan_role(cf, iam, role, names, dry_run)),
            ('keys', recorded_keys(cf, stacks), lambda key: orphan_key(cf, kms, key, dry_run))):
        for resource in resources:
            try:
                result[field] += cleanup(resource)
            except Exception as error:
                # A recorded key may already have completed its deletion window.
                if field == 'keys' and getattr(error, 'response', {}).get('Error', {}).get('Code') == 'NotFoundException':
                    continue
                failures += 1
                LOG.exception('Gate orphan cleanup failed for %s', resource)
    if failures:
        raise RuntimeError(f'Orphan cleanup failed for {failures} resource(s)')
    return result
