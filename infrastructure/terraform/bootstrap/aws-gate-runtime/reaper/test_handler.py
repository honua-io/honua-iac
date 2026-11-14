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
        with patch.dict(sys.modules, {'boto3': boto}), patch.dict(os.environ, {'SERVICE_ROLE_ARN': 'service-role'}), patch.object(handler, 'reap') as reap:
            handler.lambda_handler({}, None)
        boto.client.assert_called_once_with('cloudformation', region_name='us-east-1')
        self.assertEqual(reap.call_args.args[2], 'service-role')


if __name__ == '__main__':
    unittest.main()
