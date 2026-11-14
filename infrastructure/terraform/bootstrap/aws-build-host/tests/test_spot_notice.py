#!/usr/bin/env python3
"""Run the production spot-notice script against isolated host commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BOOTSTRAP = Path(__file__).resolve().parents[1] / 'install-gate-runner.sh'


class SpotNoticeTests(unittest.TestCase):
    def notice(self, status, heartbeat_exit='0'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / 'draining'
            capture = root / 'commands'
            stubs = {
                'curl': '[[ "$*" != *instance-action* ]] && echo token || echo "$STATUS"',
                'jq': 'echo 10',
                'systemctl': '''[[ -e "$MARKER" ]] || exit 99
printf '%s\\n' "$*" >> "$CAPTURE"
[[ "$*" != *heartbeat.timer* || "$HEARTBEAT_EXIT" == 0 ]]''',
            }
            for name, body in stubs.items():
                path = root / name
                path.write_text('#!/bin/bash\n' + body + '\n')
                path.chmod(0o755)
            script = BOOTSTRAP.read_text().split("<<'SPOT'\n", 1)[1].split('\nSPOT', 1)[0]
            script = script.replace('/run/honua-gate-runner-draining', str(marker))
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}', STATUS=status,
                       MARKER=str(marker), CAPTURE=str(capture),
                       HEARTBEAT_EXIT=heartbeat_exit)
            result = subprocess.run(['bash'], input=script, env=env, text=True,
                                    capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return marker.exists(), capture.read_text().splitlines() if capture.exists() else []

    def test_absent_notice_does_not_drain(self):
        self.assertEqual(self.notice('404'), (False, []))

    def test_marker_precedes_parallel_runner_stop(self):
        draining, calls = self.notice('200')
        self.assertTrue(draining)
        self.assertEqual(len(calls), 2)
        self.assertIn('heartbeat.timer', calls[0])
        self.assertEqual(calls[1], 'stop ' + ' '.join(
            f'honua-gate-runner@{index}.service' for index in range(1, 11)))

    def test_heartbeat_stop_failure_does_not_leave_listeners_accepting_jobs(self):
        draining, calls = self.notice('200', heartbeat_exit='1')
        self.assertTrue(draining)
        self.assertIn('honua-gate-runner@10.service', calls[-1])

    def test_restarts_and_registration_fail_closed_during_drain(self):
        source = BOOTSTRAP.read_text()
        for delimiter in ['PREPARE', 'RUN']:
            script = source.split(f"<<'{delimiter}'\n", 1)[1].split(f'\n{delimiter}', 1)[0]
            self.assertIn('[[ ! -e /run/honua-gate-runner-draining ]] || exit 1', script)
        self.assertEqual(source.count('ConditionPathExists=!/run/honua-gate-runner-draining'), 2)


if __name__ == '__main__':
    unittest.main()
