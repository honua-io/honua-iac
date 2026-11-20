import datetime as dt
import os
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, os.path.dirname(__file__))
import handler

NOW = dt.datetime(2026, 1, 2, tzinfo=dt.timezone.utc)
DOMAIN = 'gate.example.test'
ARN = 'arn:aws:acm:us-east-1:000000000002:certificate/11111111-1111-1111-1111-111111111111'
LIVE_ARN = 'arn:aws:acm:us-east-1:000000000002:certificate/22222222-2222-2222-2222-222222222222'
GATE_TAGS = {'Tags': [{'Key': 'HonuaGate', 'Value': 'true'}]}


class AwsError(Exception):
    def __init__(self, code):
        self.response = {'Error': {'Code': code, 'Message': code}}


def summary(arn=ARN, name=f'sec.{DOMAIN}', **extra):
    return {'CertificateArn': arn, 'DomainName': name, 'InUse': False, **extra}


def certificate(name=f'sec.{DOMAIN}', age=25, **extra):
    return {'DomainName': name, 'SubjectAlternativeNames': [name], 'InUseBy': [],
            'CreatedAt': NOW - dt.timedelta(hours=age), **extra}


class CertificateTests(unittest.TestCase):
    def setUp(self):
        self.cf, self.acm = Mock(), Mock()
        self.stacks = [{'StackId': 'live-id', 'StackName': 'honua-gate-live', 'StackStatus': 'UPDATE_COMPLETE'},
                       {'StackId': 'gone-id', 'StackName': 'honua-gate-gone', 'StackStatus': 'DELETE_COMPLETE'}]
        self.live_resources = [{'ResourceType': handler.CERT_TYPE, 'PhysicalResourceId': LIVE_ARN}]
        self.summaries = [summary(), summary(LIVE_ARN)]
        self.cf.get_paginator.side_effect = lambda operation: Mock(paginate=Mock(side_effect=self.cf_pages(operation)))
        self.acm.get_paginator.return_value.paginate.side_effect = lambda **kw: [
            {'CertificateSummaryList': self.summaries[:1]}, {'CertificateSummaryList': self.summaries[1:]}]
        self.acm.describe_certificate.return_value = {'Certificate': certificate()}
        self.acm.list_tags_for_certificate.return_value = GATE_TAGS

    def cf_pages(self, operation):
        if operation == 'list_stacks':
            return lambda: [{'StackSummaries': self.stacks}]
        return lambda StackName: [{'StackResourceSummaries': self.live_resources if StackName == 'live-id' else []}]

    def run_cleanup(self, dry_run=True, domain=DOMAIN, legacy=()):
        work = SimpleNamespace(cf=self.cf, acm=self.acm, now=NOW, domain=domain, legacy=set(legacy), dry_run=dry_run)
        return handler.reap_certificates(work)

    def test_default_is_logged_dry_run(self):
        with self.assertLogs(handler.LOG, level='INFO') as logs:
            self.assertEqual(self.run_cleanup(), {'certificates': 1, 'dry_run': True})
        self.acm.delete_certificate.assert_not_called()
        self.assertIn(ARN, ' '.join(logs.output))

    def test_apply_deletes_only_the_unowned_certificate(self):
        self.assertEqual(self.run_cleanup(dry_run=False)['certificates'], 1)
        self.acm.delete_certificate.assert_called_once_with(CertificateArn=ARN)
        self.acm.describe_certificate.assert_called_once_with(CertificateArn=ARN)
        includes = self.acm.get_paginator.return_value.paginate.call_args.kwargs['Includes']
        self.assertIn('EC_prime256v1', includes['keyTypes'])

    def test_no_gate_domain_reads_nothing(self):
        self.assertEqual(self.run_cleanup(domain='')['certificates'], 0)
        self.acm.get_paginator.assert_not_called()
        self.cf.get_paginator.assert_not_called()

    def test_in_use_young_or_foreign_certificates_are_kept(self):
        for detail in ({'InUseBy': ['arn:aws:cloudfront::000000000002:distribution/E1']}, {'CreatedAt': NOW},
                       {'SubjectAlternativeNames': [f'sec.{DOMAIN}', 'www.example.com']}):
            with self.subTest(detail=detail):
                self.acm.describe_certificate.return_value = {'Certificate': certificate() | detail}
                self.assertEqual(self.run_cleanup(dry_run=False)['certificates'], 0)
        self.acm.delete_certificate.assert_not_called()

    def test_imported_certificate_without_created_at_is_kept(self):
        detail = certificate()
        del detail['CreatedAt']
        self.acm.describe_certificate.return_value = {'Certificate': detail | {'ImportedAt': NOW}}
        self.assertEqual(self.run_cleanup(dry_run=False)['certificates'], 0)
        self.acm.delete_certificate.assert_not_called()

    def test_listing_filters_skip_foreign_and_in_use_without_describing(self):
        self.summaries = [summary(name='api.example.com'), summary(name=f'x.not{DOMAIN}'), summary(InUse=True)]
        self.assertEqual(self.run_cleanup(dry_run=False)['certificates'], 0)
        self.acm.describe_certificate.assert_not_called()

    def test_untagged_certificate_needs_the_temporary_id_list(self):
        self.acm.list_tags_for_certificate.return_value = {'Tags': [{'Key': 'HonuaGate', 'Value': 'false'}]}
        self.assertEqual(self.run_cleanup(dry_run=False)['certificates'], 0)
        self.acm.delete_certificate.assert_not_called()
        legacy = [ARN.rsplit('/', 1)[-1]]
        self.assertEqual(self.run_cleanup(dry_run=False, legacy=legacy)['certificates'], 1)
        self.acm.delete_certificate.assert_called_once_with(CertificateArn=ARN)

    def test_wildcard_names_count_as_under_the_domain(self):
        self.acm.describe_certificate.return_value = {'Certificate': certificate(
            SubjectAlternativeNames=[f'sec.{DOMAIN}', f'*.sec.{DOMAIN}'])}
        self.assertEqual(self.run_cleanup()['certificates'], 1)

    def test_deleted_or_newly_attached_certificate_is_idempotent(self):
        for code in handler.CERT_SKIP_ERRORS:
            with self.subTest(code=code):
                self.acm.delete_certificate.side_effect = AwsError(code)
                self.assertEqual(self.run_cleanup(dry_run=False)['certificates'], 0)

    def test_other_errors_fail_after_checking_every_certificate(self):
        self.live_resources = []
        self.acm.describe_certificate.side_effect = [AwsError('AccessDeniedException'), {'Certificate': certificate()}]
        with self.assertRaisesRegex(RuntimeError, '1 certificate'):
            self.run_cleanup(dry_run=False)
        self.acm.delete_certificate.assert_called_once_with(CertificateArn=LIVE_ARN)

    def test_too_many_live_stacks_fails_closed(self):
        self.stacks = [{'StackId': f'id-{n}', 'StackName': f'honua-gate-{n}', 'StackStatus': 'CREATE_COMPLETE'}
                       for n in range(handler.MAX_LIVE_STACKS + 1)]
        with self.assertRaisesRegex(RuntimeError, 'live stacks'):
            self.run_cleanup(dry_run=False)
        self.acm.delete_certificate.assert_not_called()

    def test_lambda_passes_domain_temporary_ids_and_dry_run(self):
        boto = Mock()
        env = {'SERVICE_ROLE_ARN': 'role', 'GATE_TEST_DOMAIN': DOMAIN, 'TEMPORARY_ORPHAN_CERTIFICATE_IDS': 'a,b',
               'ORPHAN_DRY_RUN': 'false'}
        with patch.dict(sys.modules, {'boto3': boto}), patch.dict(os.environ, env), \
                patch.object(handler, 'reap'), patch.object(handler, 'reap_orphans'), \
                patch.object(handler, 'reap_protection_trails'), patch.object(handler, 'reap_certificates') as certs:
            handler.lambda_handler({}, None)
        boto.client.assert_any_call('acm', region_name='us-east-1')
        work = certs.call_args.args[0]
        self.assertEqual((work.domain, work.legacy, work.dry_run), (DOMAIN, {'a', 'b'}, False))
        env['TEMPORARY_ORPHAN_CERTIFICATE_IDS'] = ''
        with patch.dict(sys.modules, {'boto3': boto}), patch.dict(os.environ, env), \
                patch.object(handler, 'reap'), patch.object(handler, 'reap_orphans'), \
                patch.object(handler, 'reap_protection_trails'), patch.object(handler, 'reap_certificates') as certs:
            handler.lambda_handler({}, None)
        self.assertEqual(certs.call_args.args[0].legacy, set())


if __name__ == '__main__':
    unittest.main()
