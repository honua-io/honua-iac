import os
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, os.path.dirname(__file__))
import handler

ACCOUNT = '000000000002'
GONE_ID = f'arn:aws:cloudformation:us-east-1:{ACCOUNT}:stack/honua-gate-2130z/11111111-1111-1111-1111-111111111111'
LIVE_ID = f'arn:aws:cloudformation:us-east-1:{ACCOUNT}:stack/honua-gate-live/22222222-2222-2222-2222-222222222222'


class AwsError(Exception):
    def __init__(self, code, message=None):
        self.response = {'Error': {'Code': code, 'Message': message or code}}


def secret(name, stack_id=GONE_ID, stack_name=None, **extra):
    tags = [{'Key': 'HonuaGate', 'Value': 'true'}]
    if stack_id is not None:
        tags += [{'Key': 'aws:cloudformation:stack-id', 'Value': stack_id},
                 {'Key': 'aws:cloudformation:stack-name', 'Value': stack_name or stack_id.split('/')[1]}]
    return {'ARN': f'arn:aws:secretsmanager:us-east-1:{ACCOUNT}:secret:{name}-AbCdEf', 'Name': name,
            'Tags': tags, **extra}


class SecretTests(unittest.TestCase):
    def setUp(self):
        self.cf, self.sm = Mock(), Mock()
        self.secrets = [secret('AdminSecret-gone'), secret('AdminSecret-live', LIVE_ID)]
        self.sm.get_paginator.return_value.paginate.return_value.search.side_effect = (
            lambda expression: iter(self.secrets) if expression == 'SecretList[]' else iter(()))
        self.statuses = {GONE_ID: 'DELETE_COMPLETE', LIVE_ID: 'UPDATE_COMPLETE'}
        self.parameters = {LIVE_ID: [{'ParameterKey': 'DomainName', 'ParameterValue': 'gate.example.test'}]}
        self.cf.describe_stacks.side_effect = self.describe
        self.cf.get_paginator.return_value.paginate.side_effect = lambda: [{'StackSummaries': [
            {'StackId': stack_id, 'StackName': stack_id.split('/')[1], 'StackStatus': status}
            for stack_id, status in self.statuses.items()]}]

    def describe(self, StackName):
        if StackName not in self.statuses:
            raise AwsError('ValidationError', f'Stack with id {StackName} does not exist')
        return {'Stacks': [{'StackStatus': self.statuses[StackName], 'Parameters': self.parameters.get(StackName, [])}]}

    def run_cleanup(self, dry_run=True):
        return handler.reap_secrets(SimpleNamespace(cf=self.cf, secrets=self.sm, dry_run=dry_run))

    def test_default_is_logged_dry_run(self):
        with self.assertLogs(handler.LOG, level='INFO') as logs:
            self.assertEqual(self.run_cleanup(), {'secrets': 1, 'dry_run': True})
        self.sm.delete_secret.assert_not_called()
        self.assertIn('AdminSecret-gone', ' '.join(logs.output))

    def test_apply_deletes_only_secrets_of_deleted_stacks_with_a_recovery_window(self):
        self.assertEqual(self.run_cleanup(dry_run=False)['secrets'], 1)
        self.sm.delete_secret.assert_called_once_with(SecretId=self.secrets[0]['ARN'], RecoveryWindowInDays=7)

    def test_a_stack_beyond_cloudformation_history_counts_as_gone(self):
        del self.statuses[GONE_ID]
        self.assertEqual(self.run_cleanup(dry_run=False)['secrets'], 1)

    def test_nested_stack_secrets_use_their_own_stack_id(self):
        nested = GONE_ID.replace('honua-gate-2130z', 'honua-gate-2130z-Data-ABC')
        self.statuses[nested] = 'DELETE_COMPLETE'
        self.secrets = [secret('DbSecret-nested', nested)]
        self.assertEqual(self.run_cleanup(dry_run=False)['secrets'], 1)

    def test_stack_is_described_once_for_all_of_its_secrets(self):
        self.secrets = [secret(f'Secret{n}-gone') for n in range(4)]
        self.assertEqual(self.run_cleanup(dry_run=False)['secrets'], 4)
        self.assertEqual([c.kwargs for c in self.cf.describe_stacks.call_args_list].count({'StackName': GONE_ID}), 1)

    def test_idp_untagged_foreign_and_mismatched_secrets_are_kept(self):
        foreign = GONE_ID.replace('honua-gate-2130z', 'honua-demo-demo')
        self.statuses[foreign] = 'DELETE_COMPLETE'
        self.secrets = [secret('honua-gate/idp/client-secret'), secret('untagged', stack_id=None),
                        secret('demo', foreign), secret('mismatch', GONE_ID, stack_name='honua-gate-other'),
                        secret('wrong-account', GONE_ID.replace(ACCOUNT, '000000000009'))]
        self.assertEqual(self.run_cleanup(dry_run=False)['secrets'], 0)
        self.sm.delete_secret.assert_not_called()
        self.assertNotIn({'StackName': GONE_ID}, [c.kwargs for c in self.cf.describe_stacks.call_args_list])

    def test_a_secret_a_live_stack_still_passes_as_a_parameter_is_kept(self):
        # Runtime reference: a new stack may reuse a retained key ring by ARN, partial ARN or name.
        for value in (self.secrets[0]['ARN'], self.secrets[0]['ARN'][:-7], 'AdminSecret-gone'):
            with self.subTest(value=value):
                self.parameters[LIVE_ID] = [{'ParameterKey': 'OperationKeyRingSecretArn', 'ParameterValue': value}]
                self.assertEqual(self.run_cleanup(dry_run=False)['secrets'], 0)
        self.sm.delete_secret.assert_not_called()

    def test_too_many_live_stacks_fails_closed(self):
        self.statuses = {LIVE_ID.replace('honua-gate-live', f'honua-gate-{n}'): 'CREATE_COMPLETE'
                         for n in range(handler.MAX_LIVE_STACKS + 1)} | {GONE_ID: 'DELETE_COMPLETE'}
        with self.assertRaisesRegex(RuntimeError, 'live stacks'):
            self.run_cleanup(dry_run=False)
        self.sm.delete_secret.assert_not_called()

    def test_already_deleted_or_scheduled_secrets_are_idempotent(self):
        for code in handler.SECRET_SKIP_ERRORS:
            with self.subTest(code=code):
                self.sm.delete_secret.side_effect = AwsError(code)
                self.assertEqual(self.run_cleanup(dry_run=False)['secrets'], 0)

    def test_other_errors_fail_after_checking_every_secret(self):
        self.secrets = [secret('first'), secret('second')]
        self.sm.delete_secret.side_effect = [AwsError('AccessDeniedException'), {}]
        with self.assertRaisesRegex(RuntimeError, '1 secret'):
            self.run_cleanup(dry_run=False)
        self.assertEqual(self.sm.delete_secret.call_count, 2)

    def test_unreadable_stack_keeps_its_secrets(self):
        self.statuses.pop(LIVE_ID)
        self.cf.describe_stacks.side_effect = AwsError('AccessDenied')
        with self.assertRaisesRegex(RuntimeError, '2 secret'):
            self.run_cleanup(dry_run=False)
        self.sm.delete_secret.assert_not_called()

    def test_lambda_passes_the_orphan_dry_run(self):
        boto = Mock()
        env = {'SERVICE_ROLE_ARN': 'role', 'ORPHAN_DRY_RUN': 'false'}
        with patch.dict(sys.modules, {'boto3': boto}), patch.dict(os.environ, env), \
                patch.object(handler, 'reap'), patch.object(handler, 'reap_orphans'), \
                patch.object(handler, 'reap_protection_trails'), patch.object(handler, 'reap_certificates'), \
                patch.object(handler, 'reap_secrets') as secrets:
            handler.lambda_handler({}, None)
        boto.client.assert_any_call('secretsmanager', region_name='us-east-1')
        self.assertFalse(secrets.call_args.args[0].dry_run)


if __name__ == '__main__':
    unittest.main()
