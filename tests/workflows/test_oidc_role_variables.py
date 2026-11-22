#!/usr/bin/env python3
"""Workflows must source AWS OIDC role ARNs from variables, never hardcoded account IDs."""
from pathlib import Path
import os
import re
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / '.github' / 'workflows'
HARDCODED_IAM_ARN = re.compile(r'arn:aws:iam::[0-9]{12}:role/')


def load_workflow(name):
    return yaml.safe_load((WORKFLOWS / name).read_text())


def run_require_step(step, mode, role_arn):
    env = {
        'PATH': os.environ['PATH'],
        'MODE': mode,
        'ROLE_ARN': role_arn,
    }
    return subprocess.run(['bash', '-c', step['run']], env=env, capture_output=True, text=True)


class WorkflowOidcRoleVariables(unittest.TestCase):
    def test_no_workflow_hardcodes_aws_iam_role_arn(self):
        offenders = []
        for path in sorted(WORKFLOWS.glob('*.yml')):
            text = path.read_text()
            if HARDCODED_IAM_ARN.search(text):
                offenders.append(path.name)
        self.assertEqual([], offenders, f'Hardcoded AWS IAM role ARN found in workflows: {offenders}')

    def test_release_cell_inventory_policy_requires_configured_role_vars(self):
        document = load_workflow('release-cell-inventory-policy.yml')
        steps = document['jobs']['policy']['steps']
        session = next(
            step for step in steps
            if step.get('uses', '').startswith('aws-actions/configure-aws-credentials@')
        )
        expected_expr = (
            "${{ inputs.mode == 'deploy' && vars.HONUA_AWS_CELL_INVENTORY_APPLY_ROLE_ARN"
            " || vars.HONUA_AWS_CELL_INVENTORY_PLAN_ROLE_ARN }}"
        )
        self.assertEqual(expected_expr, session['with']['role-to-assume'])

        guard = next(step for step in steps if step.get('name') == 'Require OIDC role')
        self.assertEqual(expected_expr, guard['env']['ROLE_ARN'])

        # Absent role fails closed for both modes.
        for mode in ('plan', 'deploy'):
            result = run_require_step(guard, mode, '')
            self.assertNotEqual(0, result.returncode, f'mode={mode} accepted empty ROLE_ARN')

        # Cross-mode role is rejected.
        wrong = run_require_step(
            guard, 'plan', 'arn:aws:iam::123456789012:role/honua-iac-gha-cell-inventory-apply'
        )
        self.assertNotEqual(0, wrong.returncode)

        # Matching role succeeds for both modes.
        for mode, suffix in (('plan', 'plan'), ('deploy', 'apply')):
            ok = run_require_step(
                guard, mode, f'arn:aws:iam::123456789012:role/honua-iac-gha-cell-inventory-{suffix}'
            )
            self.assertEqual(0, ok.returncode, ok.stdout + ok.stderr)


if __name__ == '__main__':
    unittest.main()
