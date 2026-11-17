import datetime as dt
import os
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, os.path.dirname(__file__))
import handler

T0 = dt.datetime(2026, 11, 17, tzinfo=dt.timezone.utc)
STATIC = ['https://localhost/admin/auth/callback']
REF = {'UserPoolId': 'pool', 'ClientId': 'client'}


def url(host):
    return f'https://{host}.cloudfront.net/admin/auth/callback'


def stack(name, callback=None, hours=0, own=None, **extra):
    outputs = [{'OutputKey': 'HonuaUrl', 'OutputValue': 'https://x'}]
    if callback:
        outputs.append({'OutputKey': 'OidcCallbackUrl', 'OutputValue': callback})
    host = callback.split('/')[2] if callback else None
    return dict(StackId=name, StackName=name, CreationTime=T0 + dt.timedelta(hours=hours),
                Outputs=outputs, Own=own or host, **({'StackStatus': 'CREATE_COMPLETE'} | extra))


def clients(stacks, current):
    cf = Mock()
    cf.get_paginator.return_value.paginate.return_value = [
        {'StackSummaries': stacks[:1]}, {'StackSummaries': stacks[1:]}]
    cf.describe_stacks.side_effect = lambda **kw: {'Stacks': [next(
        s for s in stacks if s['StackId'] == kw['StackName'])]}
    by_id = {s['StackId']: s for s in stacks}
    cf.get_paginator.side_effect = lambda op: paginators[op]
    paginators = {'list_stacks': Mock(), 'list_stack_resources': Mock()}
    paginators['list_stacks'].paginate.return_value = [
        {'StackSummaries': stacks[:1]}, {'StackSummaries': stacks[1:]}]
    paginators['list_stack_resources'].paginate.side_effect = lambda StackName: [{'StackResourceSummaries': [
        {'ResourceType': 'AWS::S3::Bucket', 'PhysicalResourceId': 'bucket'},
        {'ResourceType': 'AWS::CloudFront::Distribution', 'PhysicalResourceId': f'dist-{StackName}'}]}]
    cloudfront = Mock()
    cloudfront.get_distribution.side_effect = lambda Id: {'Distribution': {
        'DomainName': by_id[Id.removeprefix('dist-')]['Own']}}
    idp = Mock()
    idp.describe_user_pool_client.return_value = {'UserPoolClient': current}
    cf.paginators = paginators
    return (cf, cloudfront, idp), idp


def client(**extra):
    return dict(UserPoolId='pool', ClientId='client', ClientName='honua-gate-launch-stack',
                ClientSecret='never-copied', CreationDate=T0, LastModifiedDate=T0,
                AllowedOAuthFlows=['code'], AllowedOAuthScopes=['email', 'openid', 'profile'],
                AllowedOAuthFlowsUserPoolClient=True, SupportedIdentityProviders=['COGNITO'],
                PreventUserExistenceErrors='ENABLED', EnableTokenRevocation=True,
                **({'CallbackURLs': list(STATIC)} | extra))


class CallbackSyncTests(unittest.TestCase):
    def test_registers_live_gate_cloudfront_callbacks_and_preserves_settings(self):
        stacks = [stack('honua-gate-a', url('d111')), stack('production', url('d222')),
                  stack('honua-gate-nested', url('d333'), ParentId='parent'),
                  stack('honua-gate-custom', 'https://evil.example/admin/auth/callback'),
                  stack('honua-gate-pending'), stack('honua-gate-b', url('d444'), hours=1)]
        cf, idp = clients(stacks, client())
        result = handler.sync(cf, REF, STATIC)
        self.assertEqual(result, {'changed': True, 'callbacks': 3})
        cf[0].paginators['list_stacks'].paginate.assert_called_once_with(
            StackStatusFilter=list(handler.LIVE))
        kwargs = idp.update_user_pool_client.call_args.kwargs
        self.assertEqual(kwargs['CallbackURLs'], STATIC + [url('d444'), url('d111')])
        self.assertEqual(kwargs['AllowedOAuthScopes'], ['email', 'openid', 'profile'])
        self.assertTrue(kwargs['EnableTokenRevocation'])
        for key in ('ClientSecret', 'CreationDate', 'LastModifiedDate'):
            self.assertNotIn(key, kwargs)
        self.assertNotIn('never-copied', repr(result))

    def test_deleted_stacks_drop_out_and_no_change_skips_update(self):
        cf, idp = clients([stack('honua-gate-a', url('d111'))],
                          client(CallbackURLs=STATIC + [url('d111'), url('gone')]))
        handler.sync(cf, REF, STATIC)
        self.assertEqual(idp.update_user_pool_client.call_args.kwargs['CallbackURLs'],
                         STATIC + [url('d111')])
        cf, idp = clients([stack('honua-gate-a', url('d111'))],
                          client(CallbackURLs=[url('d111')] + STATIC))
        self.assertEqual(handler.sync(cf, REF, STATIC),
                         {'changed': False, 'callbacks': 2})
        idp.update_user_pool_client.assert_not_called()

    def test_callback_must_be_the_stacks_own_distribution(self):
        stacks = [stack('honua-gate-foreign', url('dforeign'), own='downed.cloudfront.net'),
                  stack('honua-gate-a', url('d111'), StackStatus='UPDATE_ROLLBACK_FAILED')]
        cf, idp = clients(stacks, client())
        handler.sync(cf, REF, STATIC)
        self.assertEqual(idp.update_user_pool_client.call_args.kwargs['CallbackURLs'],
                         STATIC + [url('d111')])
        self.assertIn('UPDATE_ROLLBACK_FAILED', handler.LIVE)

    def test_stale_default_redirect_is_dropped(self):
        cf, idp = clients([], client(DefaultRedirectURI=url('gone'),
                                     CallbackURLs=STATIC + [url('gone')]))
        handler.sync(cf, REF, STATIC)
        self.assertNotIn('DefaultRedirectURI', idp.update_user_pool_client.call_args.kwargs)

    def test_callback_limit_keeps_static_and_newest(self):
        live = [url(f'd{index}') for index in range(150)]
        callbacks = handler.desired_callbacks(STATIC, live)
        self.assertEqual(len(callbacks), handler.MAX_CALLBACKS)
        self.assertEqual(callbacks[:2], [STATIC[0], url('d0')])

    def test_only_cloudfront_hosts_match(self):
        for bad in ('http://d1.cloudfront.net/admin/auth/callback',
                    'https://d1.cloudfront.net.evil.example/admin/auth/callback',
                    'https://evil.example/d1.cloudfront.net/admin/auth/callback',
                    'https://d1.cloudfront.net/admin/auth/callback?x=1'):
            with self.subTest(bad=bad):
                self.assertIsNone(handler.CALLBACK.match(bad))
        self.assertIsNotNone(handler.CALLBACK.match(url('d1abc')))


if __name__ == '__main__':
    unittest.main()
