#!/usr/bin/env python3
"""The bootstrap drift plan is red, never skipped, and its report never leaks a secret.

honua-iac#320: a drift job that concludes green while it cannot run is the
failure mode that let the bootstrap roots drift unseen. These tests run the
real role-precondition step with the variable absent and present, pin that no
job-level condition can skip the plan, check root coverage and input rendering,
and exercise the plan classifier and its redaction.
"""
from pathlib import Path
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github' / 'workflows' / 'bootstrap-drift-plan.yml'


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


roots = load_script('bootstrap-drift-roots')
report = load_script('terraform-plan-report')


def workflow():
    return yaml.safe_load(WORKFLOW.read_text())


def step(job, name):
    return next(s for s in workflow()['jobs'][job]['steps'] if s.get('name', '').startswith(name))


def run_step(s, extra_env):
    env = {'PATH': os.environ['PATH'], **extra_env}
    return subprocess.run(['bash', '-c', s['run']], env=env, capture_output=True, text=True)


class NeverGreenWhileSkipped(unittest.TestCase):
    def test_unset_role_fails(self):
        result = run_step(step('plan', 'Require the drift role'), {'ROLE_ARN': ''})
        self.assertEqual(result.returncode, 1)
        self.assertIn('::error', result.stdout)

    def test_malformed_role_fails(self):
        result = run_step(step('plan', 'Require the drift role'), {'ROLE_ARN': 'placeholder'})
        self.assertEqual(result.returncode, 1)

    def test_configured_role_passes(self):
        result = run_step(step('plan', 'Require the drift role'), {'ROLE_ARN': 'arn:aws:iam::123456789012:role/honua-iac-bootstrap-drift-gha'})
        self.assertEqual(result.returncode, 0)

    def test_plan_job_has_no_skip_condition(self):
        self.assertNotIn('if', workflow()['jobs']['plan'])

    def test_plan_job_uses_the_trusted_environment(self):
        self.assertEqual(workflow()['jobs']['plan']['environment'], 'bootstrap-drift')

    def test_schedule_is_on(self):
        triggers = workflow()[True]  # PyYAML reads the `on:` key as boolean True
        self.assertTrue(triggers.get('schedule'))

    def test_plan_text_is_never_printed(self):
        plan = step('plan', 'terraform plan')['run']
        self.assertIn('> "$RUNNER_TEMP/plan.txt"', plan)
        self.assertNotIn('cat "$RUNNER_TEMP/plan.txt"', plan)



FAKE_AWS = r"""#!/bin/bash
case "$1 $2" in
  "s3api head-object")
    case "$FAKE_HEAD" in
      found) exit 0 ;;
      missing) echo 'An error occurred (404) when calling the HeadObject operation: Not Found' >&2; exit 254 ;;
      *) echo 'An error occurred (403) when calling the HeadObject operation: Forbidden' >&2; exit 254 ;;
    esac ;;
  "s3 cp")
    case "$FAKE_GET" in
      empty) echo '{"version": 4, "resources": []}' ;;
      populated) echo '{"version": 4, "resources": [{"type": "aws_instance"}]}' ;;
      invalid) echo 'not json' ;;
      empty-then-fail) echo '{"version": 4, "resources": []}'; exit 1 ;;
      *) echo 'download failed: AccessDenied' >&2; exit 1 ;;
    esac ;;
esac
"""

MISSING_JQ = "#!/bin/bash\necho 'jq: command not found' >&2\nexit 127\n"


class NotAppliedRootState(unittest.TestCase):
    """A not-applied root is clean only with no state object or a state object holding no resources."""

    def classify(self, head, get='empty', jq_missing=False):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            bin_dir = work / 'bin'
            bin_dir.mkdir()
            (bin_dir / 'aws').write_text(FAKE_AWS)
            (bin_dir / 'aws').chmod(0o755)
            if jq_missing:
                (bin_dir / 'jq').write_text(MISSING_JQ)
                (bin_dir / 'jq').chmod(0o755)
            (work / 'scripts').symlink_to(ROOT / 'scripts')
            env = {
                'PATH': f"{bin_dir}:{os.environ['PATH']}",
                'ROOT': 'aws-eval-docker-hosts',
                'STATE_BUCKET': 'state-bucket',
                'FAKE_HEAD': head,
                'FAKE_GET': get,
                'GITHUB_SERVER_URL': 'https://github.com',
                'GITHUB_REPOSITORY': 'honua-io/honua-iac',
                'GITHUB_RUN_ID': '1',
            }
            for name in ('Start the report', 'Never-applied root has no state'):
                result = subprocess.run(['bash', '-c', step('plan', name)['run']], env=env, cwd=work,
                                        capture_output=True, text=True)
                if result.returncode != 0:
                    break
            status = (work / 'drift-report' / 'aws-eval-docker-hosts.status').read_text().strip()
            return result.returncode, status

    def test_no_state_object_is_clean(self):
        self.assertEqual(self.classify('missing'), (0, 'clean'))

    def test_state_without_resources_is_clean(self):
        self.assertEqual(self.classify('found', 'empty'), (0, 'clean'))

    def test_state_with_resources_is_drift(self):
        self.assertEqual(self.classify('found', 'populated'), (1, 'drift'))

    def test_unreadable_state_metadata_is_an_error(self):
        code, status = self.classify('denied')
        self.assertNotEqual(code, 0)
        self.assertEqual(status, 'error')

    def test_state_that_cannot_be_downloaded_is_an_error(self):
        code, status = self.classify('found', 'denied')
        self.assertNotEqual(code, 0)
        self.assertEqual(status, 'error')

    def test_failed_download_is_an_error_even_when_it_printed_an_empty_state(self):
        code, status = self.classify('found', 'empty-then-fail')
        self.assertNotEqual(code, 0)
        self.assertEqual(status, 'error')

    def test_state_that_is_not_json_is_an_error(self):
        code, status = self.classify('found', 'invalid')
        self.assertNotEqual(code, 0)
        self.assertEqual(status, 'error')

    def test_missing_jq_is_an_error(self):
        code, status = self.classify('found', 'empty', jq_missing=True)
        self.assertNotEqual(code, 0)
        self.assertEqual(status, 'error')

class RootCoverage(unittest.TestCase):
    def test_every_bootstrap_root_is_listed(self):
        self.assertEqual(roots.problems(roots.load_manifest()), [])

    def test_unlisted_root_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            for name in ('aws-a', 'aws-b'):
                (base / name).mkdir()
                (base / name / 'main.tf').write_text('')
            manifest = {'state_key_prefix': 'bootstrap/', 'roots': {'aws-a': {'applied': False, 'state_key': 'bootstrap/aws-a/terraform.tfstate'}}}
            self.assertTrue(any('aws-b' in p for p in roots.problems(manifest, base)))

    def test_state_key_outside_the_role_prefix_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / 'aws-a').mkdir()
            (base / 'aws-a' / 'main.tf').write_text('')
            manifest = {'state_key_prefix': 'bootstrap/', 'roots': {'aws-a': {'applied': True, 'vars': {}, 'state_key': 'demo/x.tfstate'}}}
            self.assertTrue(roots.problems(manifest, base))

    def test_operator_root_needs_an_ssm_source_and_no_vars(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / 'aws-a').mkdir()
            (base / 'aws-a' / 'main.tf').write_text('')
            entry = {'applied': True, 'state_key': 'bootstrap/aws-a/terraform.tfstate',
                     'operator': {'tfvars_parameter': '/honua/a/tfvars', 'region': 'eu-north-1'}}
            manifest = {'state_key_prefix': 'bootstrap/', 'roots': {'aws-a': entry}}
            self.assertEqual(roots.problems(manifest, base), [])
            for broken in ({'applied': False}, {'vars': {}}, {'operator': {'region': 'eu-north-1'}}):
                manifest['roots']['aws-a'] = {**entry, **broken}
                self.assertTrue(roots.problems(manifest, base), broken)

    def test_operator_roots_are_never_planned_in_ci(self):
        for name in ('Setup Terraform', 'terraform init', 'terraform plan', 'Classify and report'):
            self.assertIn('!matrix.operator', step('plan', name)['if'])
        self.assertEqual(step('plan', 'Operator root has state')['if'], '${{ matrix.operator }}')

    def test_inputs_render_account_and_bucket(self):
        rendered = roots.render(roots.load_manifest()['roots']['aws-drift-plan']['vars'], '123456789012', 'bucket-x')
        self.assertEqual(rendered['state_bucket_name'], 'bucket-x')
        self.assertIn('123456789012', rendered['oidc_provider_arn'])
        self.assertNotRegex(json.dumps(rendered), r'\{(account_id|state_bucket)\}')


class PlanReport(unittest.TestCase):
    @staticmethod
    def plan(*changes):
        return {'resource_changes': list(changes), 'output_changes': {}, 'resource_drift': []}

    @staticmethod
    def change(actions, before, after, **marks):
        return {'address': 'aws_iam_role.cell["reaper"]', 'change': {'actions': actions, 'before': before, 'after': after, **marks}}

    def test_noop_is_clean(self):
        self.assertEqual(report.classify(self.plan(self.change(['no-op'], {'a': 1}, {'a': 1})), []).status, 'clean')

    def test_session_drift_is_red(self):
        result = report.classify(self.plan(self.change(['update'], {'max_session_duration': 3600}, {'max_session_duration': 7200})), [])
        self.assertEqual(result.status, 'drift')
        self.assertIn('7200', report.render(result, 't'))

    def test_sensitive_values_are_redacted(self):
        c = self.change(['update'], {'secret': 'old-value'}, {'secret': 'new-value'},
                        before_sensitive={'secret': True}, after_sensitive={'secret': True})
        text = report.render(report.classify(self.plan(c), []), 't')
        self.assertNotIn('old-value', text)
        self.assertNotIn('new-value', text)


if __name__ == '__main__':
    unittest.main()
