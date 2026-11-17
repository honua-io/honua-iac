import json
import os
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, os.path.dirname(__file__))
import handler

STATIC = ['https://localhost/admin/auth/callback']
SERVICE_ROLE = 'arn:aws:iam::000000000002:role/HonuaGateCloudFormation'
CLIENT = {
    'UserPoolId': 'us-east-1_Synthetic', 'ClientId': 'client', 'ClientName': 'honua-gate-launch-stack',
    'ClientSecret': 'never-sent', 'CreationDate': 'x', 'LastModifiedDate': 'y',
    'RefreshTokenValidity': 30, 'TokenValidityUnits': {'RefreshToken': 'days'},
    'SupportedIdentityProviders': ['COGNITO'], 'CallbackURLs': STATIC,
    'AllowedOAuthFlows': ['code'], 'AllowedOAuthScopes': ['openid', 'profile', 'email'],
    'AllowedOAuthFlowsUserPoolClient': True, 'PreventUserExistenceErrors': 'ENABLED',
    'EnableTokenRevocation': True, 'AuthSessionValidity': 3,
}


def callback(domain):
    return f'https://{domain}/admin/auth/callback'


def stack(name, domain='d111.cloudfront.net', url=None, distribution='E111', **extra):
    return {'StackId': f'id/{name}', 'StackName': name, 'StackStatus': 'CREATE_COMPLETE', 'RoleARN': SERVICE_ROLE,
            'Outputs': [{'OutputKey': 'OidcCallbackUrl', 'OutputValue': url or callback(domain)}],
            '_distribution': (distribution, domain), **extra}


class Fakes:
    def __init__(self, stacks, client=None):
        self.stacks = {s['StackId']: s for s in stacks}
        self.cf = Mock()
        pages = [{'StackSummaries': stacks[:2]}, {'StackSummaries': stacks[2:]}]
        self.cf.get_paginator.side_effect = lambda op: self.paginator(op, pages)
        self.cf.describe_stacks.side_effect = lambda StackName: {'Stacks': [self.stacks[StackName]]}
        self.cloudfront = Mock()
        domains = {s['_distribution'][0]: s['_distribution'][1] for s in stacks}
        self.cloudfront.get_distribution.side_effect = lambda Id: {'Distribution': {'Id': Id, 'DomainName': domains[Id]}}
        self.resource_pages = {}
        self.cognito = Mock()
        self.cognito.describe_user_pool_client.return_value = {'UserPoolClient': dict(client or CLIENT)}

    def paginator(self, op, pages):
        paginator = Mock()
        if op == 'list_stacks':
            paginator.paginate.return_value = pages
        else:
            paginator.paginate.side_effect = lambda StackName: self.resource_pages.get(StackName, [{'StackResourceSummaries': [{
                'ResourceType': 'AWS::CloudFront::Distribution', 'ResourceStatus': 'CREATE_COMPLETE',
                'PhysicalResourceId': self.stacks[StackName]['_distribution'][0]}]}])
        return paginator

    def sync(self, static=STATIC):
        clients = handler.Clients(self.cf, self.cloudfront, self.cognito)
        return handler.sync(clients, handler.Target('us-east-1_Synthetic', 'client', static, SERVICE_ROLE))

    def sent(self):
        return self.cognito.update_user_pool_client.call_args.kwargs


class CallbackSyncTests(unittest.TestCase):
    def test_pages_all_gate_stacks_and_registers_their_callbacks(self):
        stacks = [stack('honua-gate-a', 'd1.cloudfront.net', distribution='E1'),
                  stack('production', 'd2.cloudfront.net', distribution='E2'),
                  stack('honua-gate-c', 'd3.cloudfront.net', distribution='E3')]
        fakes = Fakes(stacks)
        result = fakes.sync()
        self.assertEqual(fakes.sent()['CallbackURLs'], sorted(STATIC + [callback('d1.cloudfront.net'), callback('d3.cloudfront.net')]))
        self.assertEqual(result, {'callbacks': 3, 'changed': True,
                                  'added': [callback('d1.cloudfront.net'), callback('d3.cloudfront.net')], 'removed': []})

    def test_live_statuses_only_are_listed(self):
        self.assertNotIn('DELETE_COMPLETE', handler.LIVE_STATUSES)
        self.assertNotIn('ROLLBACK_COMPLETE', handler.LIVE_STATUSES)
        self.assertNotIn('CREATE_IN_PROGRESS', handler.LIVE_STATUSES)
        self.assertIn('UPDATE_ROLLBACK_COMPLETE', handler.LIVE_STATUSES)

    def test_list_requests_only_live_statuses(self):
        fakes = Fakes([])
        paginator = Mock()
        paginator.paginate.return_value = []
        fakes.cf.get_paginator.side_effect = None
        fakes.cf.get_paginator.return_value = paginator
        fakes.sync()
        paginator.paginate.assert_called_once_with(StackStatusFilter=handler.LIVE_STATUSES)

    def test_skips_stacks_gone_since_listing_or_not_managed_by_the_service_role(self):
        fakes = Fakes([stack('honua-gate-gone', StackStatus='DELETE_COMPLETE'), stack('honua-gate-foreign', RoleARN='arn:aws:iam::000000000002:role/Other'),
                       stack('honua-gate-norole', RoleARN=None)])
        self.assertEqual(fakes.sync()['callbacks'], 1)
        fakes.cognito.update_user_pool_client.assert_not_called()

    def test_reads_every_resource_page_and_skips_deleted_or_failed_distributions(self):
        fakes = Fakes([stack('honua-gate-a', 'd1.cloudfront.net', distribution='E1')])
        dist = {'ResourceType': 'AWS::CloudFront::Distribution'}
        fakes.resource_pages['id/honua-gate-a'] = [
            {'StackResourceSummaries': [dist | {'PhysicalResourceId': 'Eold', 'ResourceStatus': 'DELETE_COMPLETE'},
                                        dist | {'PhysicalResourceId': 'Efail', 'ResourceStatus': 'CREATE_FAILED'}]},
            {'StackResourceSummaries': [{'ResourceType': 'AWS::S3::Bucket', 'PhysicalResourceId': 'b'},
                                        dist | {'PhysicalResourceId': 'E1', 'ResourceStatus': 'UPDATE_COMPLETE'}]}]
        self.assertEqual(fakes.sync()['added'], [callback('d1.cloudfront.net')])
        fakes.cloudfront.get_distribution.assert_called_once_with(Id='E1')

    def test_missing_distribution_skips_that_stack_only(self):
        class Missing(Exception):
            response = {'Error': {'Code': 'NoSuchDistribution'}}
        fakes = Fakes([stack('honua-gate-a', 'd1.cloudfront.net', distribution='E1'), stack('honua-gate-b', 'd2.cloudfront.net', distribution='E2')])
        lookup = fakes.cloudfront.get_distribution.side_effect
        fakes.cloudfront.get_distribution.side_effect = lambda Id: (_ for _ in ()).throw(Missing()) if Id == 'E1' else lookup(Id)
        self.assertEqual(fakes.sync()['added'], [callback('d2.cloudfront.net')])

    def test_other_distribution_errors_abort_without_writing(self):
        class Denied(Exception):
            response = {'Error': {'Code': 'AccessDenied'}}
        fakes = Fakes([stack('honua-gate-a')])
        fakes.cloudfront.get_distribution.side_effect = Denied()
        with self.assertRaises(Denied):
            fakes.sync()
        fakes.cognito.update_user_pool_client.assert_not_called()

    def test_preserves_every_client_setting_and_never_sends_the_secret(self):
        fakes = Fakes([stack('honua-gate-a')])
        fakes.sync()
        sent = fakes.sent()
        for key in ('ClientSecret', 'CreationDate', 'LastModifiedDate'):
            self.assertNotIn(key, sent)
        expected = {k: v for k, v in CLIENT.items() if k not in ('ClientSecret', 'CreationDate', 'LastModifiedDate', 'CallbackURLs')}
        self.assertEqual({k: v for k, v in sent.items() if k != 'CallbackURLs'}, expected)

    def test_deleted_stacks_drop_out_and_unchanged_lists_are_not_written(self):
        stale = callback('d9.cloudfront.net')
        fakes = Fakes([stack('honua-gate-a')], client=CLIENT | {'CallbackURLs': STATIC + [stale]})
        result = fakes.sync()
        self.assertEqual(result['removed'], [stale])
        self.assertEqual(fakes.sent()['CallbackURLs'], sorted(STATIC + [callback('d111.cloudfront.net')]))
        current = sorted(STATIC + [callback('d111.cloudfront.net')])
        fakes = Fakes([stack('honua-gate-a')], client=CLIENT | {'CallbackURLs': current})
        self.assertEqual(fakes.sync()['changed'], False)
        fakes.cognito.update_user_pool_client.assert_not_called()

    def test_ignores_nested_custom_domain_and_malformed_outputs(self):
        stacks = [stack('honua-gate-nested', ParentId='parent'),
                  stack('honua-gate-domain', url='https://maps.example.com/admin/auth/callback'),
                  stack('honua-gate-http', url='http://d111.cloudfront.net/admin/auth/callback'),
                  stack('honua-gate-path', url='https://d111.cloudfront.net/admin/auth/callback/extra'),
                  stack('honua-gate-host', url='https://d111.cloudfront.net.evil.example/admin/auth/callback'),
                  {'StackId': 'id/honua-gate-none', 'StackName': 'honua-gate-none', 'StackStatus': 'CREATE_COMPLETE',
                   '_distribution': ('E0', 'd0.cloudfront.net')}]
        fakes = Fakes(stacks)
        self.assertEqual(fakes.sync()['callbacks'], 1)
        fakes.cognito.update_user_pool_client.assert_not_called()

    def test_rejects_a_cloudfront_domain_the_stack_does_not_own(self):
        fakes = Fakes([stack('honua-gate-a', 'd1.cloudfront.net', distribution='E1')])
        fakes.cloudfront.get_distribution.side_effect = lambda Id: {'Distribution': {'Id': Id, 'DomainName': 'dother.cloudfront.net'}}
        self.assertEqual(fakes.sync()['callbacks'], 1)
        fakes.cognito.update_user_pool_client.assert_not_called()

    def test_any_lookup_failure_aborts_without_writing(self):
        fakes = Fakes([stack('honua-gate-a'), stack('honua-gate-b', 'd2.cloudfront.net', distribution='E2')])
        fakes.cf.describe_stacks.side_effect = RuntimeError('throttled')
        with self.assertRaisesRegex(RuntimeError, 'throttled'):
            fakes.sync()
        fakes.cognito.update_user_pool_client.assert_not_called()

    def test_more_than_one_hundred_callbacks_fails_closed(self):
        stacks = [stack(f'honua-gate-{i}', f'd{i}.cloudfront.net', distribution=f'E{i}') for i in range(100)]
        fakes = Fakes(stacks)
        with self.assertRaisesRegex(RuntimeError, '100'):
            fakes.sync()
        fakes.cognito.update_user_pool_client.assert_not_called()

    def test_default_redirect_must_stay_registered(self):
        fakes = Fakes([], client=CLIENT | {'CallbackURLs': STATIC + [callback('d9.cloudfront.net')], 'DefaultRedirectURI': callback('d9.cloudfront.net')})
        with self.assertRaisesRegex(RuntimeError, 'DefaultRedirectURI'):
            fakes.sync()
        fakes.cognito.update_user_pool_client.assert_not_called()

    def test_handler_ignores_the_event_and_reads_configuration(self):
        boto = Mock()
        env = {'USER_POOL_ID': 'pool', 'CLIENT_ID': 'client', 'STATIC_CALLBACK_URLS': json.dumps(STATIC), 'SERVICE_ROLE_ARN': SERVICE_ROLE}
        with patch.dict(sys.modules, {'boto3': boto}), patch.dict(os.environ, env), patch.object(handler, 'sync', return_value={}) as sync:
            handler.lambda_handler({'CallbackURLs': ['https://attacker.example/admin/auth/callback']}, None)
        sync.assert_called_once()
        self.assertEqual(sync.call_args.args[1], handler.Target('pool', 'client', STATIC, SERVICE_ROLE))
        boto.client.assert_any_call('cloudformation', region_name='us-east-1')
        boto.client.assert_any_call('cognito-idp', region_name='us-east-1')


if __name__ == '__main__':
    unittest.main()
