"""Delete expired, unprotected top-level gate stacks in the gate region."""
import datetime as dt
import logging
import os
import re
from types import SimpleNamespace

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


def env_dry_run(*names):
    for name in names:
        if name in os.environ:
            return os.environ[name].lower() != 'false'
    return True


def lambda_handler(event, context):
    import boto3
    cf = boto3.client('cloudformation', region_name='us-east-1')
    result = reap(cf, dt.datetime.now(dt.timezone.utc), os.environ['SERVICE_ROLE_ARN'])
    result['orphans'] = reap_orphans(
        cf, boto3.client('iam'), boto3.client('kms', region_name='us-east-1'),
        dry_run=env_dry_run('ORPHAN_DRY_RUN'))
    result['protection'] = reap_protection_trails(
        cf, boto3.client('cloudtrail', region_name='us-east-1'),
        boto3.client('s3', region_name='us-east-1'))
    result['certificates'] = reap_certificates(SimpleNamespace(
        cf=cf, acm=boto3.client('acm', region_name='us-east-1'), now=dt.datetime.now(dt.timezone.utc),
        domain=os.environ.get('GATE_TEST_DOMAIN', ''),
        legacy=set(filter(None, os.environ.get('TEMPORARY_ORPHAN_CERTIFICATE_IDS', '').split(','))),
        dry_run=env_dry_run('ORPHAN_DRY_RUN')))
    result['secrets'] = reap_secrets(SimpleNamespace(
        cf=cf, secrets=boto3.client('secretsmanager', region_name='us-east-1'),
        dry_run=env_dry_run('ORPHAN_DRY_RUN')))
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


TRAIL_PREFIX = 'honua-protection-'
BUCKET_PREFIX = 'honua-gate-'
AUDIT_MARKER = 'honua-audit'
BUCKET_MARKER = '-protectiontrailbucket-'
GUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
MAX_LIVE_STACKS = 50
DELETE_PAGE = 1000
TRAIL_TYPE = 'AWS::CloudTrail::Trail'
BUCKET_TYPE = 'AWS::S3::Bucket'


def aws_error_code(error):
    return getattr(error, 'response', {}).get('Error', {}).get('Code')


def audit_name(name):
    return AUDIT_MARKER in (name or '')


def protection_guid(name):
    if not name or not name.startswith(TRAIL_PREFIX) or audit_name(name):
        return None
    guid = name[len(TRAIL_PREFIX):]
    return guid if GUID.fullmatch(guid) else None


def gate_bucket(name):
    return bool(name) and name.startswith(BUCKET_PREFIX) and not audit_name(name)


def home_region_is_gate(trail):
    return trail.get('HomeRegion', 'us-east-1') == 'us-east-1'


def live_stacks(stacks):
    # The reaper can list resources only for honua-gate stacks. Other live stacks are not owners
    # this role is allowed to see, and counting them would fail the run before any cleanup.
    live = [stack for stack in stacks
            if stack.get('StackStatus') != 'DELETE_COMPLETE' and stack.get('StackName', '').startswith(BUCKET_PREFIX)]
    if len(live) > MAX_LIVE_STACKS:
        raise RuntimeError(f'{len(live)} live stacks exceed the trail ownership check')
    return live


def stack_guid(stack):
    return stack.get('StackId', '').rsplit('/', 1)[-1]


def stack_has_resource(cf, stack, physical):
    pages = cf.get_paginator('list_stack_resources').paginate(StackName=stack['StackId'])
    resources = (item for page in pages for item in page['StackResourceSummaries'])
    resource_type, physical_id = physical
    return any(item.get('ResourceType') == resource_type and item.get('PhysicalResourceId') == physical_id
               for item in resources)


def live_stack_uses(work, physical, guid=None):
    for stack in live_stacks(work.stacks):
        if guid and stack_guid(stack) == guid:
            return True
        if stack_has_resource(work.cf, stack, physical):
            return True
    return False


def listed_trails(cloudtrail):
    return cloudtrail.describe_trails(includeShadowTrails=False).get('trailList', [])


def listed_stacks(cf):
    pages = cf.get_paginator('list_stacks').paginate()
    return [stack for page in pages for stack in page['StackSummaries']]


def trail_is_orphaned(work, trail):
    guid = protection_guid(trail.get('Name', ''))
    if guid is None or not gate_bucket(trail.get('S3BucketName', '')) or not home_region_is_gate(trail):
        return False
    return not live_stack_uses(work, (TRAIL_TYPE, trail['Name']), guid)


def log_cleanup(work, message, *args):
    LOG.info('%s ' + message, 'Would' if work.dry_run else 'Will', *args)


def delete_versions(s3, bucket):
    pages = s3.get_paginator('list_object_versions').paginate(Bucket=bucket)
    for page in pages:
        objects = [{'Key': item['Key'], 'VersionId': item['VersionId']}
                   for key in ('Versions', 'DeleteMarkers') for item in page.get(key, [])]
        for start in range(0, len(objects), DELETE_PAGE):
            chunk = objects[start:start + DELETE_PAGE]
            errors = s3.delete_objects(
                Bucket=bucket, Delete={'Objects': chunk, 'Quiet': True}).get('Errors')
            if errors:
                raise RuntimeError(f'Could not empty {bucket}')


def abort_uploads(s3, bucket):
    pages = s3.get_paginator('list_multipart_uploads').paginate(Bucket=bucket)
    for page in pages:
        for upload in page.get('Uploads', []):
            s3.abort_multipart_upload(Bucket=bucket, Key=upload['Key'], UploadId=upload['UploadId'])


def remove_bucket(work, bucket):
    log_cleanup(work, 'empty and delete bucket %s', bucket)
    if work.dry_run:
        return 1
    try:
        delete_versions(work.s3, bucket)
        abort_uploads(work.s3, bucket)
        work.s3.delete_bucket(Bucket=bucket)
    except Exception as error:
        if aws_error_code(error) != 'NoSuchBucket':
            raise
    return 1


def remove_trail(work, trail):
    log_cleanup(work, 'delete trail %s', trail['Name'])
    if work.dry_run:
        return 1
    try:
        work.cloudtrail.delete_trail(Name=trail['Name'])
    except Exception as error:
        if aws_error_code(error) != 'TrailNotFoundException':
            raise
    return 1


def leftover_stack_name(bucket, trails):
    referenced = {trail.get('S3BucketName') for trail in trails}
    if bucket in referenced or not gate_bucket(bucket) or BUCKET_MARKER not in bucket:
        return None
    stack_name = bucket.split(BUCKET_MARKER, 1)[0]
    if not stack_name.startswith(BUCKET_PREFIX):
        return None
    return stack_name


def other_trail_keeps_bucket(work, trail, bucket):
    return any(other is not trail and other not in work.chosen and other.get('S3BucketName') == bucket
               for other in work.trails)


def cleanup_one(work, trail):
    counts = {'trails': remove_trail(work, trail), 'buckets': 0}
    bucket = trail.get('S3BucketName')
    if bucket in work.removed or not gate_bucket(bucket) or other_trail_keeps_bucket(work, trail, bucket):
        return counts
    if live_stack_uses(work, (BUCKET_TYPE, bucket)):
        return counts
    counts['buckets'] = remove_bucket(work, bucket)
    work.removed.add(bucket)
    return counts


def cleanup_leftover_buckets(work):
    deleted = 0
    for bucket in work.s3.list_buckets().get('Buckets', []):
        name = bucket['Name']
        stack_name = leftover_stack_name(name, work.trails)
        if stack_name is None or name in work.removed:
            continue
        if not stack_is_gone(work.cf, stack_name) or live_stack_uses(work, (BUCKET_TYPE, name)):
            continue
        deleted += remove_bucket(work, name)
        work.removed.add(name)
    return deleted


def reap_protection_trails(cf, cloudtrail, s3):
    dry_run = env_dry_run('TRAIL_CLEANUP_DRY_RUN', 'ORPHAN_DRY_RUN')
    work = SimpleNamespace(
        cf=cf, cloudtrail=cloudtrail, s3=s3, dry_run=dry_run, removed=set(),
        stacks=listed_stacks(cf), trails=[])
    live_stacks(work.stacks)
    work.trails = listed_trails(cloudtrail)
    work.chosen = [trail for trail in work.trails if trail_is_orphaned(work, trail)]
    chosen = work.chosen
    result = {'trails': 0, 'buckets': 0, 'dry_run': dry_run}
    failures = 0
    for trail in chosen:
        try:
            counts = cleanup_one(work, trail)
            result['trails'] += counts['trails']
            result['buckets'] += counts['buckets']
        except Exception:
            failures += 1
            LOG.exception('Protection trail cleanup failed for %s', trail.get('Name'))
    try:
        result['buckets'] += cleanup_leftover_buckets(work)
    except Exception:
        failures += 1
        LOG.exception('Protection bucket cleanup failed')
    if failures:
        raise RuntimeError(f'Protection cleanup failed for {failures} resource(s)')
    return result


CERT_TYPE = 'AWS::CertificateManager::Certificate'
# ListCertificates returns only RSA_2048 certificates unless key types are named.
CERT_KEY_TYPES = ['RSA_1024', 'RSA_2048', 'RSA_3072', 'RSA_4096', 'EC_prime256v1', 'EC_secp384r1', 'EC_secp521r1']
CERT_SKIP_ERRORS = ('ResourceNotFoundException', 'ResourceInUseException')


def under_domain(name, domain):
    name = (name or '').lower().removeprefix('*.')
    return bool(domain) and (name == domain or name.endswith('.' + domain))


def live_certificates(cf, stacks):
    """Certificates that a live gate stack still lists as resources; their stack owns them."""
    owned = set()
    for stack in live_stacks(stacks):
        pages = cf.get_paginator('list_stack_resources').paginate(StackName=stack['StackId'])
        owned.update(item['PhysicalResourceId'] for page in pages for item in page['StackResourceSummaries']
                     if item.get('ResourceType') == CERT_TYPE and item.get('PhysicalResourceId'))
    return owned


def gate_owned(work, arn):
    if arn.rsplit('/', 1)[-1] in work.legacy:
        return True
    tags = work.acm.list_tags_for_certificate(CertificateArn=arn).get('Tags', [])
    return any(tag['Key'] == GATE_TAG and tag.get('Value') == 'true' for tag in tags)


def orphan_certificate(work, arn):
    certificate = work.acm.describe_certificate(CertificateArn=arn)['Certificate']
    names = [certificate['DomainName'], *certificate.get('SubjectAlternativeNames', [])]
    created = certificate.get('CreatedAt')  # imported certificates carry ImportedAt instead; never gate-owned
    if (certificate.get('InUseBy') or not created or work.now - created <= MAX_AGE
            or not all(under_domain(name, work.domain) for name in names) or not gate_owned(work, arn)):
        return 0
    LOG.info('%s delete unused gate certificate %s (%s)', 'Would' if work.dry_run else 'Will', arn,
             certificate['DomainName'])
    if not work.dry_run:
        work.acm.delete_certificate(CertificateArn=arn)
    return 1


def reap_certificates(work):
    """Delete unused gate certificates under the gate test domain that no live gate stack owns."""
    result = {'certificates': 0, 'dry_run': work.dry_run}
    if not work.domain:
        return result
    owned = live_certificates(work.cf, listed_stacks(work.cf))
    pages = work.acm.get_paginator('list_certificates').paginate(Includes={'keyTypes': CERT_KEY_TYPES})
    chosen = [summary['CertificateArn'] for page in pages for summary in page['CertificateSummaryList']
              if under_domain(summary.get('DomainName'), work.domain) and not summary.get('InUse')
              and summary['CertificateArn'] not in owned]
    failures = 0
    for arn in chosen:
        try:
            result['certificates'] += orphan_certificate(work, arn)
        except Exception as error:
            # Already deleted, or attached since the listing: ACM refuses, nothing to clean.
            if aws_error_code(error) in CERT_SKIP_ERRORS:
                continue
            failures += 1
            LOG.exception('Gate certificate cleanup failed for %s', arn)
    if failures:
        raise RuntimeError(f'Certificate cleanup failed for {failures} certificate(s)')
    return result


SECRET_STACK_ID_TAG = 'aws:cloudformation:stack-id'
SECRET_STACK_NAME_TAG = 'aws:cloudformation:stack-name'
IDP_SECRET_PREFIX = 'honua-gate/idp/'
SECRET_RECOVERY_DAYS = 7
SECRET_SKIP_ERRORS = ('ResourceNotFoundException', 'InvalidRequestException')


def secret_stack(secret):
    """The gate stack ARN a CloudFormation-created secret names in its own tags, or None."""
    if secret['Name'].startswith(IDP_SECRET_PREFIX) or secret.get('DeletedDate'):
        return None
    tags = {tag['Key']: tag.get('Value', '') for tag in secret.get('Tags', [])}
    name, stack_id = tags.get(SECRET_STACK_NAME_TAG, ''), tags.get(SECRET_STACK_ID_TAG, '')
    account = secret['ARN'].split(':')[4]
    if not (name.startswith('honua-gate-')
            and stack_id.startswith(f'arn:aws:cloudformation:us-east-1:{account}:stack/{name}/')):
        return None
    return stack_id


def referenced_secrets(cf):
    """Parameter values of live gate stacks: a new stack may reuse a retained secret (runtime reference)."""
    values = set()
    for stack in live_stacks(listed_stacks(cf)):
        for described in cf.describe_stacks(StackName=stack['StackId'])['Stacks']:
            values.update(item.get('ParameterValue', '') for item in described.get('Parameters', []))
    return values - {''}


def still_referenced(secret, references):
    arn = secret['ARN']
    return secret['Name'] in references or any(
        value.startswith('arn:') and arn.startswith(value) for value in references)


def orphan_secret(work, secret, gone):
    stack_id = secret_stack(secret)
    if stack_id is None:
        return 0
    if still_referenced(secret, work.references):
        LOG.info('Keep secret %s: a live gate stack still passes it as a parameter', secret['Name'])
        return 0
    if stack_id not in gone:
        gone[stack_id] = stack_is_gone(work.cf, stack_id)
    if not gone[stack_id]:
        return 0
    LOG.info('%s delete secret %s with a %d-day recovery window (stack %s)', 'Would' if work.dry_run else 'Will',
             secret['Name'], SECRET_RECOVERY_DAYS, stack_id)
    if not work.dry_run:
        work.secrets.delete_secret(SecretId=secret['ARN'], RecoveryWindowInDays=SECRET_RECOVERY_DAYS)
    return 1


def reap_secrets(work):
    """Delete secrets that deleted gate stacks retained (the template keeps them by design)."""
    result = {'secrets': 0, 'dry_run': work.dry_run}
    gone = {}
    failures = 0
    work.references = referenced_secrets(work.cf)
    for page in work.secrets.get_paginator('list_secrets').paginate():
        for secret in page['SecretList']:
            try:
                result['secrets'] += orphan_secret(work, secret, gone)
            except Exception as error:
                # Already deleted or scheduled; or refused (replicas, service-managed): logged, not retried.
                if aws_error_code(error) in SECRET_SKIP_ERRORS:
                    LOG.info('Skip secret %s: %s', secret.get('Name'), aws_error_code(error))
                    continue
                failures += 1
                LOG.exception('Gate secret cleanup failed for %s', secret.get('Name'))
    if failures:
        raise RuntimeError(f'Secret cleanup failed for {failures} secret(s)')
    return result
