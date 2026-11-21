#!/usr/bin/env python3
"""Scheduled cleanup jobs skip, never fail, when their OIDC role is unprovisioned.

honua-release#376 (R18/R21): an env-gated lane whose backend is not provisioned
concludes `skipped` with the named precondition. These tests run the real
precondition step script from each workflow with the variable absent and
present, and pin the job wiring so the missing role is the only skip path.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / '.github' / 'workflows'

CASES = {
    'terraform-validation-infra-reaper.yml': ('reap', 'HONUA_AWS_VALIDATION_REAPER_ROLE_ARN'),
    'terraform-validation-iam-sweeper.yml': ('sweep', 'HONUA_AWS_VALIDATION_IAM_SWEEPER_ROLE_ARN'),
    'release-cell-reaper.yml': ('reap', 'HONUA_AWS_CELL_REAPER_ROLE_ARN'),
}
# The operator action each skip notice must name.
SKIP_ACTIONS = {
    'release-cell-reaper.yml': ('bootstrap/aws-release-cells', 'environment:aws-cell-reaper'),
}
DEFAULT_SKIP_ACTION = ('#208', 'teardown deny')
# A role ARN each precondition accepts.
PRESENT_ROLES = {
    'release-cell-reaper.yml': 'arn:aws:iam::123456789012:role/honua-release-cell-reaper',
}
DEFAULT_PRESENT_ROLE = 'arn:aws:iam::123456789012:role/cleanup'


def load(name):
    return yaml.safe_load((WORKFLOWS / name).read_text())


def precondition_step(document):
    steps = document['jobs']['precondition']['steps']
    return next(step for step in steps if step.get('id') == 'role')


def run_step(step, role_arn):
    with tempfile.TemporaryDirectory() as tmp:
        output = Path(tmp) / 'output'
        summary = Path(tmp) / 'summary'
        output.touch()
        summary.touch()
        env = {
            'PATH': os.environ['PATH'],
            'ROLE_ARN': role_arn,
            'GITHUB_OUTPUT': str(output),
            'GITHUB_STEP_SUMMARY': str(summary),
        }
        result = subprocess.run(['bash', '-c', step['run']], env=env, capture_output=True, text=True)
        return result, output.read_text(), summary.read_text()


class CleanupRolePrecondition(unittest.TestCase):
    def test_absent_role_skips_with_named_variable_and_operator_action(self):
        for name, (_, variable) in CASES.items():
            with self.subTest(workflow=name):
                result, output, summary = run_step(precondition_step(load(name)), '')
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual('configured=false\n', output)
                notices = [line for line in result.stdout.splitlines() if line.startswith('::notice')]
                self.assertEqual(1, len(notices), result.stdout)
                for text in (notices[0], summary):
                    self.assertIn('SKIPPED', text)
                    self.assertIn(variable, text)
                    for phrase in SKIP_ACTIONS.get(name, DEFAULT_SKIP_ACTION):
                        self.assertIn(phrase, text)
                self.assertEqual(1, len(summary.strip().splitlines()))

    def test_present_role_runs_the_cleanup(self):
        for name in CASES:
            with self.subTest(workflow=name):
                result, output, summary = run_step(
                    precondition_step(load(name)), PRESENT_ROLES.get(name, DEFAULT_PRESENT_ROLE))
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual('configured=true\n', output)
                self.assertNotIn('::notice', result.stdout)
                self.assertEqual('', summary)

    def test_release_cell_precondition_rejects_other_roles(self):
        step = precondition_step(load('release-cell-reaper.yml'))
        result, output, _ = run_step(step, 'arn:aws:iam::123456789012:role/cleanup')
        self.assertNotEqual(0, result.returncode)
        self.assertEqual('', output)
        self.assertIn('honua-release-cell-reaper', result.stdout)

    def test_missing_role_is_the_only_skip_path(self):
        for name, (job_name, variable) in CASES.items():
            with self.subTest(workflow=name):
                document = load(name)
                pre = document['jobs']['precondition']
                job = document['jobs'][job_name]
                self.assertEqual('${{ steps.role.outputs.configured }}', pre['outputs']['configured'])
                self.assertEqual('${{ vars.%s }}' % variable, precondition_step(document)['env']['ROLE_ARN'])
                self.assertEqual('precondition', job['needs'])
                self.assertEqual("${{ needs.precondition.outputs.configured == 'true' }}", job['if'])
                # The precondition checks the same role the cleanup job assumes.
                session = next(step for step in job['steps']
                               if step.get('uses', '').startswith('aws-actions/configure-aws-credentials@'))
                self.assertEqual('${{ vars.%s }}' % variable, session['with']['role-to-assume'])
                # A present role still runs the original fail-closed guard and sweep.
                guard = next(step for step in job['steps'] if step.get('name') == 'Require OIDC role')
                self.assertEqual('${{ vars.%s }}' % variable, guard['env']['ROLE_ARN'])
                self.assertTrue(any('sweep-orphaned-validation-' in step.get('run', '') for step in job['steps']))
                # Nothing else in the workflow carries a job- or step-level skip condition.
                self.assertNotIn('if', pre)
                self.assertFalse([step for step in job['steps'] if 'if' in step])
                self.assertEqual({'precondition', job_name}, set(document['jobs']))


if __name__ == '__main__':
    unittest.main()
