import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('idle', ROOT / 'lane-idle-stop.py')
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)


def row(command, parent=1, start='123'):
    return {'comm': Path(command[0]).name, 'argv': command, 'parent': parent, 'start': start}


class ActivityTests(unittest.TestCase):
    def test_agents_reviews_remote_waits_and_unknown_processes_are_busy(self):
        commands = [['codex', 'exec'], ['claude', '-p'], ['bash', './run-sol.sh', 'lane'],
                    ['bash', 'codex-review'], ['bash', 'remote-run'], ['ssh', 'build'],
                    ['sleep', '600'], ['unknown-worker']]
        rows = {100 + i: row(command) for i, command in enumerate(commands)}
        self.assertEqual(sorted(rows), idle.busy_processes(rows, {}))

    def test_idle_daemon_sleep_ignored_but_active_descendants_count(self):
        rows = {10: row(['bash', './lane-keeper']), 11: row(['sleep', '600'], 10),
                12: row(['bash', './run-sol.sh', 'lane'], 10), 13: row(['ssh', 'build'], 12)}
        self.assertEqual([12, 13], idle.busy_processes(rows, {'passive_commands': [['bash', './lane-keeper']]}))

    def test_prompt_mentions_do_not_hide_work(self):
        rows = {10: row(['bash', '-c', 'echo lane-keeper']), 11: row(['codex', 'exec', 'lane-keeper'])}
        self.assertEqual([10, 11], idle.busy_processes(rows, {'passive_commands': [['bash', './lane-keeper']]}))

    def test_pid_reuse_does_not_preserve_maintenance_exemption(self):
        self.assertEqual([10], idle.busy_processes({10: row(['bash', 'job'], start='456')},
                                                  {'passive_processes': {'10': '123'}}))

    def test_persistent_config_required_and_threshold_cannot_be_overridden(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config'
            persistent = Path(directory) / 'persistent'
            config.write_text(idle.json.dumps({'activity_config': str(persistent), 'idle_seconds': 1800}))
            with patch.object(idle, 'CONFIG', config):
                with self.assertRaises(FileNotFoundError):
                    idle.load_config()
                persistent.write_text('{"work_probe": []}')
                with self.assertRaises(ValueError):
                    idle.load_config()
                persistent.write_text('{"work_probe": ["probe"], "idle_seconds": 1}')
                self.assertEqual(1800, idle.load_config()['idle_seconds'])
                self.assertEqual(['probe'], idle.load_config()['work_probe'])

    def test_shared_admission_lock_prevents_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            lock, state = Path(directory) / 'lock', Path(directory) / 'state'
            state.write_text('1')
            with lock.open('w') as author, patch.object(idle, 'LOCK', lock), \
                 patch.object(idle, 'STATE', state), patch.object(idle.time, 'monotonic', return_value=5000), \
                 patch.object(idle, 'activity') as inspect:
                idle.fcntl.flock(author, idle.fcntl.LOCK_SH)
                idle.evaluate({}, False)
                inspect.assert_not_called()
                self.assertEqual('5000', state.read_text())

    def test_probe_failure_inhibits_shutdown(self):
        with patch.object(idle.subprocess, 'run') as run:
            run.return_value.returncode = 1
            self.assertIn('probe failed', idle.activity({'work_probe': ['check-work']}))

    def test_state_window_and_recheck(self):
        with tempfile.TemporaryDirectory() as directory:
            state, lock = Path(directory) / 'state', Path(directory) / 'lock'
            with patch.object(idle, 'STATE', state), patch.object(idle, 'LOCK', lock), \
                 patch.object(idle, 'STOPPING', Path(directory) / 'stopping'), \
                 patch.object(idle.time, 'monotonic', return_value=2000), \
                 patch.object(idle, 'activity', return_value=''), patch.object(idle.subprocess, 'run') as run:
                idle.evaluate({}, False)
                run.assert_not_called()
                self.assertEqual('2000', state.read_text())
                state.write_text('201')
                idle.evaluate({}, False)
                run.assert_not_called()
                state.write_text('200')
                idle.evaluate({}, True)
                run.assert_not_called()
                with patch.object(idle, 'activity', side_effect=['', 'new job']):
                    idle.evaluate({}, False)
                run.assert_not_called()
                self.assertEqual('2000', state.read_text())
                state.write_text('200')
                idle.evaluate({}, False)
                run.assert_called_once_with(['systemctl', 'poweroff'], check=True, timeout=30)

    def test_busy_activity_resets_full_idle_window(self):
        with tempfile.TemporaryDirectory() as directory:
            state, lock = Path(directory) / 'state', Path(directory) / 'lock'
            state.write_text('1')
            with patch.object(idle, 'STATE', state), patch.object(idle, 'LOCK', lock), \
                 patch.object(idle.time, 'monotonic', return_value=5000), \
                 patch.object(idle, 'activity', return_value='agent active'), \
                 patch.object(idle.subprocess, 'run') as run:
                idle.evaluate({}, False)
                self.assertEqual('5000', state.read_text())
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
