#!/usr/bin/env python3
"""Certification workflows must never fall back to static keys or mint new ones."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[5]

class OidcContract(unittest.TestCase):
    def test_no_static_aws_credentials_or_user_bootstrap(self):
        for path in (ROOT / '.github/workflows').glob('terraform-*.yml'):
            source = path.read_text()
            self.assertNotIn('secrets.AWS_ACCESS_KEY_ID', source, path)
            self.assertNotIn('secrets.AWS_SECRET_ACCESS_KEY', source, path)
            self.assertNotIn('create_access_key=true', source, path)
            self.assertNotIn('output -raw secret_access_key', source, path)

    def test_live_jobs_use_oidc_and_refresh_separate_cleanup_identity(self):
        document = yaml.safe_load((ROOT / '.github/workflows/terraform-manual-validation.yml').read_text())
        for name in ['aws-live', 'eks-live']:
            job = document['jobs'][name]
            self.assertEqual('write', job['permissions']['id-token'])
            sessions = [s for s in job['steps'] if s.get('uses', '').startswith('aws-actions/configure-aws-credentials@')]
            self.assertEqual(2, len(sessions))
            self.assertNotEqual(sessions[0]['with']['role-to-assume'], sessions[1]['with']['role-to-assume'])
            self.assertIn('always()', sessions[1]['if'])
            for session in sessions:
                self.assertTrue(session['with']['unset-current-credentials'])
                self.assertIn('vars.HONUA_AWS_', session['with']['role-to-assume'])
                self.assertNotIn('aws-access-key-id', session['with'])

    def test_scheduled_cleanup_authenticates_before_sweep(self):
        for name in ['terraform-validation-iam-sweeper.yml', 'terraform-validation-infra-reaper.yml']:
            document = yaml.safe_load((ROOT / '.github/workflows' / name).read_text())
            self.assertEqual('write', document['permissions']['id-token'])
            job = next(iter(document['jobs'].values()))
            sessions = [i for i, step in enumerate(job['steps']) if step.get('uses', '').startswith('aws-actions/configure-aws-credentials@')]
            self.assertEqual(1, len(sessions))
            sweep = next(i for i, step in enumerate(job['steps']) if 'sweep-orphaned-validation-' in step.get('run', ''))
            self.assertLess(sessions[0], sweep)

if __name__ == '__main__':
    unittest.main()
