#!/usr/bin/env python3
"""Run the production quiet-window script and idle-stop guard against isolated host commands."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parents[1]
INSTALLER = (HERE / 'install-quiet-window.sh').read_text()
SCRIPT = INSTALLER.split("<<'QUIET'\n", 1)[1].split('\nQUIET\n', 1)[0]
IDLE_STOP = (HERE / 'install-idle-stop.sh').read_text().split("<<'PYTHON'\n", 1)[1].split('\nPYTHON\n', 1)[0]

# pgrep: a runner is busy while its counter file holds a positive number of remaining polls.
PGREP = '''user="$2"
[[ -n "${RESUME_ON_POLL:-}" && -f "$STATE/busy-${user#gate-runner-}" ]] && rm -f "$STATE/window.hold"
counter="$STATE/busy-${user#gate-runner-}"
[[ -f "$counter" ]] || exit 1
left="$(< "$counter")"; (( left > 0 )) || exit 1
echo $((left - 1)) > "$counter"'''
# GitHub refuses to delete a runner that holds a job (422): a refuse-N file stands for that.
REGISTRATION = '''[[ "$1" == remove && ! -e "$STATE/refuse-$2" ]] || exit 1
printf 'deregister %s\\n' "$2" >> "$STATE/commands"'''
SYSTEMCTL = '''printf '%s\\n' "$*" >> "$STATE/commands"
index="${*: -1}"; index="${index#honua-gate-runner@}"; index="${index%.service}"
case "$1" in
  stop) [[ -f "$STATE/busy-$index" && "$(< "$STATE/busy-$index")" -gt 0 ]] && echo "KILLED $index" >> "$STATE/commands"
        touch "$STATE/stopped-$index" ;;
  start) rm -f "$STATE/stopped-$index" ;;
  is-active) [[ ! -e "$STATE/stopped-${index}" ]] ;;
esac'''


class QuietWindowTests(unittest.TestCase):
    def run_window(self, arguments, busy=None, pools=('gate', 'gate', 'heavy'), env=None, refuse=()):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        state = Path(directory.name)
        (state / 'config.json').write_text(json.dumps({'runners': [{'pool': pool} for pool in pools]}))
        for index, polls in (busy or {}).items():
            (state / f'busy-{index}').write_text(str(polls))
        for index in refuse:
            (state / f'refuse-{index}').touch()
        for name, body in {'pgrep': PGREP, 'systemctl': SYSTEMCTL, 'registration': REGISTRATION}.items():
            (state / name).write_text('#!/bin/bash\n' + body + '\n')
            (state / name).chmod(0o755)
        script = (SCRIPT.replace('/etc/honua-gate-runner.json', str(state / 'config.json'))
                  .replace('/usr/local/sbin/honua-gate-runner-registration', str(state / 'registration'))
                  .replace('/run/honua-quiet-window', str(state / 'window')))
        run_env = dict(os.environ, PATH=f'{state}:{os.environ["PATH"]}', STATE=str(state),
                       HONUA_QUIET_POLL_SECONDS='0', **(env or {}))
        result = subprocess.run(['bash', '-s', '--', *arguments], input=script, env=run_env,
                                text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = (state / 'commands').read_text().splitlines() if (state / 'commands').exists() else []
        status = (state / 'window').read_text() if (state / 'window').exists() else ''
        return state, commands, status

    def test_drain_waits_for_a_busy_runner_and_never_kills_it(self):
        state, commands, status = self.run_window(['drain'], busy={2: 3})
        self.assertFalse([line for line in commands if line.startswith('KILLED')], commands)
        stops = [line for line in commands if line.startswith('stop')]
        self.assertEqual(stops, ['stop honua-gate-runner@1.service', 'stop honua-gate-runner@3.service',
                                 'stop honua-gate-runner@2.service'])
        self.assertTrue((state / 'window.hold').exists())
        self.assertRegex(status, r'^open until=\d+ busy=0 drained=3/3 load=\S+ at=\S+Z\n$')

    def test_drain_gives_up_after_the_wait_and_leaves_the_job_running(self):
        state, commands, status = self.run_window(['drain'], busy={1: 10_000},
                                                  env={'HONUA_QUIET_WAIT_SECONDS': '0'})
        self.assertNotIn('stop honua-gate-runner@1.service', commands)
        self.assertTrue((state / 'window.hold').exists(), 'the hold keeps it from restarting after its job')
        self.assertIn(' busy=1 drained=2/3 ', status)

    def test_resume_lifts_the_hold_and_starts_every_runner(self):
        state, commands, status = self.run_window(['resume'])
        self.assertFalse((state / 'window.hold').exists())
        self.assertEqual([line for line in commands if line.startswith('start')],
                         [f'start --no-block honua-gate-runner@{index}.service' for index in (1, 2, 3)])
        self.assertTrue(status.startswith('closed drained=0/3 load='))

    def test_boot_drain_outside_the_window_changes_nothing(self):
        later = time.strftime('%H:%M', time.gmtime(time.time() + 7200))
        later_end = time.strftime('%H:%M', time.gmtime(time.time() + 7260))
        state, commands, status = self.run_window(['drain', '--if-open'],
                                                  env={'HONUA_QUIET_START': later, 'HONUA_QUIET_END': later_end})
        self.assertEqual((commands, status), ([], ''))
        self.assertFalse((state / 'window.hold').exists())

    def test_only_gate_and_heavy_pools_are_drained(self):
        _, commands, status = self.run_window(['drain'], pools=('gate', 'light', 'heavy'))
        self.assertEqual([line for line in commands if line.startswith('stop')],
                         ['stop honua-gate-runner@1.service', 'stop honua-gate-runner@3.service'])
        self.assertIn(' drained=2/2 ', status)

    def test_a_runner_github_will_not_deregister_is_never_stopped(self):
        # A listener can hold an accepted job before Runner.Worker starts; GitHub then refuses.
        _, commands, status = self.run_window(['drain'], refuse=(2,), env={'HONUA_QUIET_WAIT_SECONDS': '0'})
        self.assertNotIn('stop honua-gate-runner@2.service', commands)
        self.assertEqual([line for line in commands if line.split()[0] in ('deregister', 'stop')],
                         ['deregister 1', 'stop honua-gate-runner@1.service',
                          'deregister 3', 'stop honua-gate-runner@3.service'])
        self.assertIn(' busy=1 drained=2/3 ', status)

    def test_resume_during_a_drain_ends_it_without_stopping_restarted_runners(self):
        _, commands, _ = self.run_window(['drain'], busy={1: 1}, env={'RESUME_ON_POLL': '1'})
        self.assertNotIn('stop honua-gate-runner@1.service', commands)

    def test_boot_drain_inside_the_window_drains(self):
        # A whole-day window, so the test cannot straddle midnight.
        if time.gmtime().tm_hour == 23 and time.gmtime().tm_min >= 58:
            self.skipTest('too close to midnight UTC')
        state, _, status = self.run_window(['drain', '--if-open'],
                                           env={'HONUA_QUIET_START': '00:00', 'HONUA_QUIET_END': '23:59'})
        self.assertTrue((state / 'window.hold').exists())
        self.assertIn(' drained=3/3 ', status)

    def test_runner_unit_refuses_to_start_while_held(self):
        self.assertIn('ConditionPathExists=!/run/honua-quiet-window.hold', INSTALLER)
        self.assertIn('OnCalendar=*-*-* ${when} UTC', INSTALLER)
        self.assertIn("when='12:00:00'", INSTALLER)
        self.assertIn("when='13:15:00'", INSTALLER)
        self.assertIn('Conflicts=honua-quiet-window-drain.service honua-quiet-window-boot.service', INSTALLER)


class IdleStopGuardTests(unittest.TestCase):
    def guard(self, text):
        namespace = {'__name__': 'idle_stop'}
        exec(compile(IDLE_STOP, 'idle-stop', 'exec'), namespace)
        with tempfile.TemporaryDirectory() as directory:
            window = Path(directory) / 'window'
            if text is not None:
                window.write_text(text)
            namespace['QUIET_WINDOW'] = window
            return namespace['in_quiet_window']()

    def test_open_window_keeps_the_host_up_only_until_its_end(self):
        now = int(time.time())
        self.assertTrue(self.guard(f'open until={now + 600} busy=0 drained=10/10 load=1 at=x\n'))
        self.assertFalse(self.guard(f'open until={now - 1} busy=0 drained=10/10 load=1 at=x\n'))
        self.assertFalse(self.guard('closed drained=0/10 load=1 at=x\n'))
        self.assertFalse(self.guard('open busy=0\n'))
        self.assertFalse(self.guard(None))


if __name__ == '__main__':
    unittest.main()
