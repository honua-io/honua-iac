import datetime as dt
import os
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, os.path.dirname(__file__))
import handler

NOW = dt.datetime(2026, 1, 2, tzinfo=dt.timezone.utc)


def stack(name='honua-gate-old', age=25, **extra):
    return dict(StackId=name, StackName=name, CreationTime=NOW-dt.timedelta(hours=age),
                StackStatus='CREATE_COMPLETE', **extra)


class ReaperTests(unittest.TestCase):
    def run_reaper(self, stacks, details):
        client = Mock()
        client.get_paginator.return_value.paginate.return_value = [
            {'StackSummaries': stacks[:2]}, {'StackSummaries': stacks[2:]}]
        client.describe_stacks.side_effect = lambda **kw: {'Stacks': [details[kw['StackName']]]}
        result = handler.reap(client, NOW, 'service-role')
        return client, result

    def test_pages_prefix_age_nested_and_keep(self):
        stacks = [stack(), stack('production'), stack('honua-gate-new', 24),
                  stack('honua-gate-nested', ParentId='parent'), stack('honua-gate-kept')]
        details = {s['StackId']: s for s in stacks}
        details['honua-gate-kept']['Tags'] = [{'Key': 'keep', 'Value': 'false'}]
        client, result = self.run_reaper(stacks, details)
        client.delete_stack.assert_called_once_with(StackName='honua-gate-old', RoleARN='service-role')
        self.assertEqual(result, {'deleted': 1})

    def test_refresh_checks_keep_and_termination_protection(self):
        for extra in ({'EnableTerminationProtection': True}, {'Tags': [{'Key': 'keep', 'Value': ''}]},
                      {'ParentId': 'parent'}, {'StackStatus': 'DELETE_IN_PROGRESS'}):
            with self.subTest(extra=extra):
                client, result = self.run_reaper([stack()], {'honua-gate-old': stack() | extra})
                client.delete_stack.assert_not_called()
                self.assertEqual(result['deleted'], 0)

    def test_partial_failure_is_reported_after_other_stacks(self):
        client = Mock()
        client.get_paginator.return_value.paginate.return_value = [{'StackSummaries': [stack(), stack('honua-gate-next')]}]
        client.describe_stacks.side_effect = [RuntimeError('denied'), {'Stacks': [stack('honua-gate-next')]}]
        with self.assertRaisesRegex(RuntimeError, '1 stack'):
            handler.reap(client, NOW, 'service-role')
        client.delete_stack.assert_called_once_with(StackName='honua-gate-next', RoleARN='service-role')

    def test_deletion_in_progress_is_idempotent(self):
        client, result = self.run_reaper([stack(StackStatusReason='retry') | {'StackStatus': 'DELETE_IN_PROGRESS'}], {})
        client.describe_stacks.assert_not_called()
        self.assertEqual(result['deleted'], 0)

    def test_lambda_always_uses_regional_client(self):
        boto = Mock()
        with patch.dict(sys.modules, {'boto3': boto}), patch.dict(os.environ, {'SERVICE_ROLE_ARN': 'service-role'}), patch.object(handler, 'reap') as reap, patch.object(handler, 'reap_orphans') as orphans, patch.object(handler, 'reap_protection_trails') as trails, patch.object(handler, 'reap_secrets'):
            handler.lambda_handler({}, None)
        boto.client.assert_any_call('cloudformation', region_name='us-east-1')
        boto.client.assert_any_call('kms', region_name='us-east-1')
        boto.client.assert_any_call('cloudtrail', region_name='us-east-1')
        boto.client.assert_any_call('s3', region_name='us-east-1')
        self.assertTrue(orphans.call_args.kwargs['dry_run'])
        self.assertEqual(len(trails.call_args.args), 3)
        self.assertEqual(reap.call_args.args[2], 'service-role')


class AwsError(Exception):
    def __init__(self, code, message):
        self.response = {'Error': {'Code': code, 'Message': message}}


class OrphanTests(unittest.TestCase):
    def setUp(self):
        self.cf, self.iam, self.kms = Mock(), Mock(), Mock()
        self.cf.get_paginator.return_value.paginate.return_value = [
            {'StackSummaries': [stack() | {'StackStatus': 'DELETE_COMPLETE'}]}]
        self.cf.get_paginator.side_effect = lambda operation: Mock(paginate=Mock(return_value=(
            [{'StackSummaries': [stack() | {'StackStatus': 'DELETE_COMPLETE'}]}]
            if operation == 'list_stacks' else [{'StackResourceSummaries': [
                {'ResourceType': 'AWS::KMS::Key', 'PhysicalResourceId': 'key'}]}])))
        self.cf.describe_stacks.side_effect = AwsError(
            'ValidationError', 'Stack with id honua-gate-old does not exist')
        self.iam.get_paginator.return_value.paginate.return_value = [
            {'Roles': [{'RoleName': 'honua-gate-old-exec'}]}]
        self.iam.list_role_tags.return_value = {'Tags': []}
        self.kms.get_paginator.return_value.paginate.return_value = [
            {'Keys': [{'KeyId': 'key'}]}]
        self.kms.list_resource_tags.return_value = {'Tags': [
            {'TagKey': 'HonuaGate', 'TagValue': 'true'}]}
        self.kms.describe_key.return_value = {'KeyMetadata': {
            'KeyManager': 'CUSTOMER', 'KeyState': 'Enabled'}}

    def run_cleanup(self, **kwargs):
        return handler.reap_orphans(self.cf, self.iam, self.kms, **kwargs)

    def test_default_is_logged_dry_run(self):
        with self.assertLogs(handler.LOG, level='INFO') as logs:
            self.assertEqual(self.run_cleanup(), {'roles': 1, 'keys': 1, 'dry_run': True})
        self.iam.delete_role.assert_not_called()
        self.kms.schedule_key_deletion.assert_not_called()
        self.assertIn('honua-gate-old-exec', ' '.join(logs.output))
        self.assertIn('key', ' '.join(logs.output))

    def test_apply_detaches_paginated_policies_before_deleting_role(self):
        def pages(operation):
            return Mock(paginate=Mock(return_value={
                'list_roles': [{'Roles': [{'RoleName': 'honua-gate-old-exec'}]}],
                'list_role_policies': [{'PolicyNames': ['one']}, {'PolicyNames': ['two']}],
                'list_attached_role_policies': [{'AttachedPolicies': [{'PolicyArn': 'managed'}]}],
            }[operation]))
        self.iam.get_paginator.side_effect = pages
        result = self.run_cleanup(dry_run=False)
        self.assertFalse(result['dry_run'])
        self.iam.delete_role_policy.assert_any_call(RoleName='honua-gate-old-exec', PolicyName='two')
        self.iam.detach_role_policy.assert_called_once_with(RoleName='honua-gate-old-exec', PolicyArn='managed')
        calls = self.iam.mock_calls
        self.assertLess(calls.index(unittest.mock.call.detach_role_policy(
            RoleName='honua-gate-old-exec', PolicyArn='managed')),
            calls.index(unittest.mock.call.delete_role(RoleName='honua-gate-old-exec')))
        self.kms.schedule_key_deletion.assert_called_once_with(KeyId='key', PendingWindowInDays=7)

    def test_every_live_stack_status_protects_resources(self):
        for status in ('CREATE_IN_PROGRESS', 'DELETE_IN_PROGRESS', 'DELETE_FAILED', 'CREATE_COMPLETE'):
            with self.subTest(status=status):
                self.cf.describe_stacks.side_effect = None
                self.cf.describe_stacks.return_value = {'Stacks': [stack() | {'StackStatus': status}]}
                self.assertEqual(self.run_cleanup()['roles'], 0)
                self.assertEqual(self.run_cleanup()['keys'], 0)

    def test_unknown_and_unrelated_resources_are_untouched(self):
        self.iam.get_paginator.return_value.paginate.return_value = [{'Roles': [
            {'RoleName': 'production'}, {'RoleName': 'honua-gate-unknown-exec'},
            {'RoleName': 'honua-gate-older-exec'}]}]
        self.kms.list_resource_tags.return_value = {'Tags': []}
        self.assertEqual(self.run_cleanup(), {'roles': 0, 'keys': 0, 'dry_run': True})
        self.cf.describe_stacks.assert_not_called()

    def test_describe_access_failure_fails_closed(self):
        self.cf.describe_stacks.side_effect = AwsError('AccessDenied', 'denied')
        with self.assertRaisesRegex(RuntimeError, 'cleanup failed'):
            self.run_cleanup(dry_run=False)
        self.iam.delete_role.assert_not_called()
        self.kms.schedule_key_deletion.assert_not_called()

    def test_deleted_history_does_not_override_recreated_stack(self):
        self.cf.describe_stacks.side_effect = None
        self.cf.describe_stacks.return_value = {'Stacks': [stack()]}
        self.assertEqual(self.run_cleanup()['roles'], 0)

    def test_pending_or_aws_managed_keys_are_skipped(self):
        for metadata in ({'KeyState': 'PendingDeletion', 'KeyManager': 'CUSTOMER'},
                         {'KeyState': 'PendingReplicaDeletion', 'KeyManager': 'CUSTOMER'},
                         {'KeyState': 'Enabled', 'KeyManager': 'AWS'}):
            self.kms.describe_key.return_value = {'KeyMetadata': metadata}
            self.assertEqual(self.run_cleanup()['keys'], 0)

    def test_paginated_key_tags_and_resource_history(self):
        self.kms.list_resource_tags.side_effect = [
            {'Tags': [], 'Truncated': True, 'NextMarker': 'next'},
            {'Tags': [{'TagKey': 'HonuaGate', 'TagValue': 'true'}]}]
        self.assertEqual(self.run_cleanup()['keys'], 1)
        self.kms.list_resource_tags.assert_called_with(KeyId='key', Marker='next')
        self.cf.get_paginator.assert_any_call('list_stack_resources')

    def test_unrecorded_key_is_never_inspected_or_deleted(self):
        self.cf.get_paginator.side_effect = None
        self.cf.get_paginator.return_value.paginate.return_value = [{'StackSummaries': []}]
        self.assertEqual(self.run_cleanup()['keys'], 0)
        self.kms.describe_key.assert_not_called()
        self.kms.schedule_key_deletion.assert_not_called()

    def test_completed_key_deletion_is_idempotent(self):
        self.kms.describe_key.side_effect = AwsError('NotFoundException', 'deleted')
        self.assertEqual(self.run_cleanup()['keys'], 0)
        self.kms.schedule_key_deletion.assert_not_called()

    def test_active_longer_prefix_prevents_short_deleted_owner_match(self):
        self.cf.get_paginator.side_effect = None
        self.cf.get_paginator.side_effect = lambda operation: Mock(paginate=Mock(return_value=(
            [{'StackSummaries': [stack() | {'StackStatus': 'DELETE_COMPLETE'},
                                 stack('honua-gate-old-exec')]}]
            if operation == 'list_stacks' else [{'StackResourceSummaries': []}])))
        self.cf.describe_stacks.side_effect = None
        self.cf.describe_stacks.return_value = {'Stacks': [stack('honua-gate-old-exec')]}
        self.assertEqual(self.run_cleanup()['roles'], 0)
        self.cf.describe_stacks.assert_called_once_with(StackName='honua-gate-old-exec')


GUID = '12345678-1234-1234-1234-123456789012'
TRAIL_NAME = f'honua-protection-{GUID}'
BUCKET_NAME = 'honua-gate-old-protectiontrailbucket-ab'


def protection_trail(name=TRAIL_NAME, bucket=BUCKET_NAME, **extra):
    return {'Name': name, 'S3BucketName': bucket, 'HomeRegion': 'us-east-1', **extra}


def stack_id(name, guid):
    return f'arn:aws:cloudformation:us-east-1:1:stack/{name}/{guid}'


class ProtectionTests(unittest.TestCase):
    def setUp(self):
        self.cf, self.cloudtrail, self.s3 = Mock(), Mock(), Mock()
        self.cf.get_paginator.return_value.paginate.return_value = [
            {'StackSummaries': [stack() | {
                'StackStatus': 'DELETE_COMPLETE', 'StackId': stack_id('honua-gate-old', GUID)}]}]
        self.cloudtrail.describe_trails.return_value = {'trailList': [protection_trail()]}
        self.s3.list_buckets.return_value = {'Buckets': []}
        self.s3.get_paginator.return_value.paginate.return_value = [
            {'Versions': [{'Key': 'log', 'VersionId': '1'}], 'DeleteMarkers': []}]
        self.s3.delete_objects.return_value = {}

    def run_cleanup(self, apply=False):
        with patch.dict(os.environ, {'TRAIL_CLEANUP_DRY_RUN': 'false' if apply else 'true'}):
            return handler.reap_protection_trails(self.cf, self.cloudtrail, self.s3)

    def test_dry_run_plans_an_orphaned_gate_trail_and_bucket(self):
        with self.assertLogs(handler.LOG, level='INFO') as logs:
            self.assertEqual(self.run_cleanup(), {'trails': 1, 'buckets': 1, 'dry_run': True})
        self.cloudtrail.delete_trail.assert_not_called()
        self.s3.delete_bucket.assert_not_called()
        self.assertIn(TRAIL_NAME, ' '.join(logs.output))
        self.assertIn(BUCKET_NAME, ' '.join(logs.output))

    def test_apply_deletes_the_trail_then_empties_and_deletes_the_bucket(self):
        self.assertEqual(self.run_cleanup(apply=True), {'trails': 1, 'buckets': 1, 'dry_run': False})
        self.cloudtrail.delete_trail.assert_called_once_with(Name=TRAIL_NAME)
        self.s3.delete_objects.assert_called_once()
        self.s3.delete_bucket.assert_called_once_with(Bucket=BUCKET_NAME)
        calls = self.s3.mock_calls
        self.assertLess(calls.index(unittest.mock.call.delete_objects(
            Bucket=BUCKET_NAME, Delete={'Objects': [{'Key': 'log', 'VersionId': '1'}], 'Quiet': True})),
            calls.index(unittest.mock.call.delete_bucket(Bucket=BUCKET_NAME)))

    def test_live_owning_stack_and_live_consumer_are_kept(self):
        live = stack() | {'StackStatus': 'CREATE_COMPLETE', 'StackId': stack_id('honua-gate-old', GUID)}
        self.cf.get_paginator.return_value.paginate.return_value = [{'StackSummaries': [live]}]
        self.assertEqual(self.run_cleanup(apply=True)['trails'], 0)
        consumer = stack('honua-gate-other') | {
            'StackStatus': 'CREATE_COMPLETE', 'StackId': stack_id('honua-gate-other', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')}
        gone = stack() | {'StackStatus': 'DELETE_COMPLETE', 'StackId': stack_id('honua-gate-old', GUID)}

        def pages(operation):
            if operation == 'list_stacks':
                return Mock(paginate=Mock(return_value=[{'StackSummaries': [gone, consumer]}]))
            return Mock(paginate=Mock(return_value=[{'StackResourceSummaries': [
                {'ResourceType': 'AWS::CloudTrail::Trail', 'PhysicalResourceId': TRAIL_NAME}]}]))

        self.cf.get_paginator.side_effect = pages
        self.assertEqual(self.run_cleanup(apply=True)['trails'], 0)
        self.cloudtrail.delete_trail.assert_not_called()
        self.s3.delete_bucket.assert_not_called()

    def test_foreign_audit_and_wrong_bucket_or_region_are_kept(self):
        foreign = [
            protection_trail('honua-audit', 'honua-audit'),
            protection_trail('customer-trail', 'customer-bucket'),
            protection_trail(f'honua-protection-not-a-guid', BUCKET_NAME),
            protection_trail(bucket='honua-audit'),
            protection_trail(bucket='other-logs'),
            protection_trail(HomeRegion='us-west-2'),
        ]
        for trail in foreign:
            with self.subTest(trail=trail['Name'], bucket=trail['S3BucketName'], region=trail['HomeRegion']):
                self.cloudtrail.describe_trails.return_value = {'trailList': [trail]}
                self.assertEqual(self.run_cleanup(apply=True)['trails'], 0)
        self.cloudtrail.delete_trail.assert_not_called()
        self.s3.delete_bucket.assert_not_called()

    def test_missing_trail_still_removes_its_bucket(self):
        self.cloudtrail.delete_trail.side_effect = AwsError('TrailNotFoundException', 'missing')
        self.assertEqual(self.run_cleanup(apply=True)['buckets'], 1)
        self.s3.delete_bucket.assert_called_once_with(Bucket=BUCKET_NAME)

    def test_missing_bucket_is_idempotent(self):
        self.s3.delete_objects.side_effect = AwsError('NoSuchBucket', 'missing')
        self.assertEqual(self.run_cleanup(apply=True), {'trails': 1, 'buckets': 1, 'dry_run': False})

    def test_version_delete_errors_do_not_delete_the_bucket(self):
        self.s3.delete_objects.return_value = {'Errors': [{'Key': 'log'}]}
        with self.assertRaisesRegex(RuntimeError, 'Protection cleanup failed'):
            self.run_cleanup(apply=True)
        self.s3.delete_bucket.assert_not_called()

    def test_one_failure_does_not_skip_the_next_trail(self):
        second = protection_trail(f'honua-protection-abcdefab-cdef-abcd-efab-cdefabcdefab',
                                  'honua-gate-next-protectiontrailbucket-cd')
        self.cloudtrail.describe_trails.return_value = {'trailList': [protection_trail(), second]}
        self.cloudtrail.delete_trail.side_effect = [RuntimeError('denied'), None]
        with self.assertRaisesRegex(RuntimeError, '1 resource'):
            self.run_cleanup(apply=True)
        self.cloudtrail.delete_trail.assert_any_call(Name=second['Name'])

    def test_leftover_gate_bucket_is_removed_only_after_its_stack_is_gone(self):
        self.cloudtrail.describe_trails.return_value = {'trailList': []}
        self.s3.list_buckets.return_value = {'Buckets': [{'Name': BUCKET_NAME}, {'Name': 'honua-audit'},
                                                         {'Name': 'honua-gate-old-console-ab'}]}
        self.cf.describe_stacks.side_effect = AwsError(
            'ValidationError', 'Stack with id honua-gate-old does not exist')
        self.assertEqual(self.run_cleanup(apply=True), {'trails': 0, 'buckets': 1, 'dry_run': False})
        self.s3.delete_bucket.assert_called_once_with(Bucket=BUCKET_NAME)
        self.cf.describe_stacks.side_effect = None
        self.cf.describe_stacks.return_value = {'Stacks': [stack()]}
        self.s3.delete_bucket.reset_mock()
        self.assertEqual(self.run_cleanup(apply=True)['buckets'], 0)
        self.s3.delete_bucket.assert_not_called()

    def test_non_gate_live_stack_is_outside_the_readable_set(self):
        foreign = stack('production') | {
            'StackStatus': 'CREATE_COMPLETE',
            'StackId': stack_id('production', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')}
        gone = stack() | {'StackStatus': 'DELETE_COMPLETE', 'StackId': stack_id('honua-gate-old', GUID)}

        def pages(operation):
            if operation == 'list_stacks':
                return Mock(paginate=Mock(return_value=[{'StackSummaries': [gone, foreign]}]))
            raise AssertionError(operation)

        self.cf.get_paginator.side_effect = pages
        self.assertEqual(self.run_cleanup(apply=True)['trails'], 1)
        self.cloudtrail.delete_trail.assert_called_once_with(Name=TRAIL_NAME)

    def test_a_surviving_trail_keeps_the_shared_bucket(self):
        kept = protection_trail('customer-trail', BUCKET_NAME)
        self.cloudtrail.describe_trails.return_value = {'trailList': [protection_trail(), kept]}
        self.assertEqual(self.run_cleanup(apply=True), {'trails': 1, 'buckets': 0, 'dry_run': False})
        self.s3.delete_bucket.assert_not_called()

    def test_too_many_live_stacks_fails_closed(self):
        live = [stack(f'honua-gate-{index}') | {'StackStatus': 'CREATE_COMPLETE'} for index in range(51)]
        self.cf.get_paginator.return_value.paginate.return_value = [{'StackSummaries': live}]
        with self.assertRaisesRegex(RuntimeError, '51 live stacks'):
            self.run_cleanup(apply=True)
        self.cloudtrail.delete_trail.assert_not_called()


if __name__ == '__main__':
    unittest.main()
