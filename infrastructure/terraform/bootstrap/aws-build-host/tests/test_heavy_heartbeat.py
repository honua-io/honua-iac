#!/usr/bin/env python3
"""Exercise the embedded heartbeat without reading or changing a real host."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BOOTSTRAP = Path(__file__).resolve().parents[1] / 'install-gate-runner.sh'


class HeavyHeartbeatTests(unittest.TestCase):
    def publish(self, scenario):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'config.json'
            config.write_text(json.dumps({'region': 'test', 'heartbeat_parameter': '/test',
                                          'runners': scenario['runners']}))
            self.write_stubs(root)
            script = BOOTSTRAP.read_text().split("<<'HEARTBEAT'\n", 1)[1].split('\nHEARTBEAT', 1)[0]
            script = script.replace('/etc/honua-gate-runner.json', str(config))
            script = script.replace('/snap/bin/aws', str(root / 'aws'))
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                       LISTENERS=scenario.get('listeners', '1 2 3 4'),
                       WORKERS=scenario.get('workers', ''),
                       OFFLINE=scenario.get('offline', ''), PROBE_ERRORS=scenario.get('probe_errors', ''), CAPTURE=str(root / 'payload.json'))
            subprocess.run(['bash'], input=script, env=env, text=True,
                                    capture_output=True, check=True)
            return json.loads((root / 'payload.json').read_text())

    @staticmethod
    def write_stubs(root):
        stubs = {
            'curl': 'echo i-current',
            'systemctl': 'index="${3#honua-gate-runner@}"; index="${index%.service}"; [[ " $OFFLINE " != *" $index "* ]]',
            'pgrep': '[[ " $PROBE_ERRORS " != *" $4 "* ]] || exit 2; index="${2#gate-runner-}"; values="$LISTENERS"; [[ "$4" != Runner.Worker ]] || values="$WORKERS"; [[ " $values " == *" $index "* ]]',
            'aws': 'while (( $# )); do if [[ "$1" == --value ]]; then echo "$2" > "$CAPTURE"; break; fi; shift; done',
        }
        for name, body in stubs.items():
            path = root / name
            path.write_text('#!/bin/bash\n' + body + '\n')
            path.chmod(0o755)

    def test_pool_observation_is_independent_and_fails_closed(self):
        runners = [{'pool': 'gate', 'labels': ['honua-build']}] * 2 + [
            {'pool': 'heavy', 'labels': ['honua-heavy']}] * 2
        cases = [
            ({'workers': '1 2'}, 0, 2),
            ({'workers': '3 4'}, 2, 0),
            ({'listeners': '1 2'}, 2, 0),
            ({'offline': '3 4'}, 2, 0),
            ({'workers': '3'}, 2, 1),
            ({'probe_errors': 'Runner.Worker'}, 2, 0),
            ({'probe_errors': 'Runner.Listener'}, 0, 0),
            ({'runners': runners + [{'pool': 'unknown', 'labels': []}]}, 2, 0),
            ({'runners': runners + [{'labels': []}]}, 2, 0),
            ({'runners': runners[:2]}, 2, 0),
            ({'runners': runners[:2] + [{'pool': 'heavy', 'labels': ['honua-build']}]}, 2, 0),
            ({'runners': runners[:2] + runners[2:] * 5}, 2, 0),
            ({'runners': runners + [{'pool': 'heavy', 'labels': None}]}, 2, 0),
            ({'runners': runners + [{'pool': 'heavy', 'labels': 'honua-heavy'}]}, 2, 0),
        ]
        for overrides, gate_idle, heavy_idle in cases:
            with self.subTest(overrides=overrides):
                payload = self.publish({'runners': runners, **overrides})
                self.assertEqual(payload['idle'], gate_idle)
                self.assertEqual(payload['heavy'], {'version': 1, 'idle': heavy_idle})
                self.assertEqual(payload['instance'], 'i-current')
                self.assertIsInstance(payload['at'], int)


if __name__ == '__main__':
    unittest.main()
