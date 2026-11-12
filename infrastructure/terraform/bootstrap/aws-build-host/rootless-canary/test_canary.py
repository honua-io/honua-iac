import copy
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import call, patch

import admission
import guard
import manifest
import prepare


class NamespaceTests(unittest.TestCase):
    def setUp(self):
        self.config = {'index': 1, 'uid': 1001, 'boot_id': 'boot-a',
                       'host_namespaces': {'net': 10, 'mnt': 11, 'user': 12}}
        self.evidence = {'child': '1', 'uid_map': [[0, 1001, 1], [1, 200000, 65536]],
                         'boot_id': 'boot-a', 'namespaces': {'net': 20, 'mnt': 21, 'user': 22}}

    def test_private_child(self):
        guard.check_namespace(self.config, self.evidence)

    def test_each_host_namespace_rejected(self):
        for name in self.config['host_namespaces']:
            evidence = copy.deepcopy(self.evidence)
            evidence['namespaces'][name] = self.config['host_namespaces'][name]
            with self.subTest(name=name), self.assertRaises(ValueError):
                guard.check_namespace(self.config, evidence)

    def test_wrong_child_uid_or_boot_rejected(self):
        for key, value in [('child', None), ('child', '2'), ('uid_map', [[0, 1002, 1]]),
                           ('uid_map', [[0, 1001, 65536]]), ('boot_id', 'boot-b')]:
            evidence = dict(self.evidence, **{key: value})
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                guard.check_namespace(self.config, evidence)

    def test_failed_guard_never_writes_allocator(self):
        with patch.object(guard, 'evidence', return_value=dict(self.evidence, child='0')):
            with patch.object(Path, 'write_text') as write, self.assertRaises(ValueError):
                guard.allocate(self.config)
            write.assert_not_called()

    def test_account_ranges_are_disjoint_and_avoid_host_default(self):
        ranges = [set(range(20000 + i * 1000, 21000 + i * 1000)) for i in range(10)]
        self.assertEqual(10000, len(set.union(*ranges)))
        self.assertLess(max(set.union(*ranges)), 32768)


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.safe = {'mask': True, 'state': 'inactive', 'main_pid': '0', 'job': '',
                     'processes': [], 'registered': [], 'registration_file': False}

    def test_fully_drained(self):
        self.assertTrue(admission.drained(self.safe))

    def test_each_incomplete_observation_rejected(self):
        for key, value in [('mask', False), ('state', 'active'), ('state', 'deactivating'),
                           ('main_pid', '15'), ('job', '123'), ('processes', [99]),
                           ('registered', [432]), ('registration_file', True)]:
            with self.subTest(key=key):
                self.assertFalse(admission.drained(dict(self.safe, **{key: value})))

    def test_assignment_race_naturally_drains_without_stop(self):
        class FakeHost:
            excluded = False
            observations = iter([dict(self.safe, processes=[1], registered=[2]), self.safe])
            def exclude(inner):
                inner.excluded = True
            def snapshot(inner):
                self.assertTrue(inner.excluded)
                return next(inner.observations)
        host = FakeHost()
        with patch.object(admission.time, 'sleep'):
            result = admission.drain(host, admission.time.monotonic() + 30)
        self.assertEqual(self.safe, result['snapshot'])

    def test_idle_listener_times_out_and_keeps_barrier(self):
        class FakeHost:
            excluded = False
            def exclude(inner):
                inner.excluded = True
            def snapshot(inner):
                return dict(self.safe, state='active')
        host = FakeHost()
        with patch.object(admission.time, 'monotonic', side_effect=[1, 3]):
            with patch.object(admission.time, 'sleep'), self.assertRaises(TimeoutError):
                admission.drain(host, 2)
        self.assertTrue(host.excluded)

    def test_snapshot_pins_registration_host_despite_cli_environment(self):
        host = object.__new__(admission.Host)
        host.unit, host.org, host.prefix = 'runner.service', 'honua-io', 'i-12345678-1-'
        host.uid, host.subordinate, host.index = 1001, (200000, 65536), 1
        properties = 'ActiveState=inactive\nMainPID=0\nJob=\nLoadState=masked'
        pages = '[{"runners":[{"id":42,"name":"i-12345678-1-123"}]}]'
        with patch.dict(os.environ, GH_HOST='other.example'):
            with patch.object(admission, 'command', side_effect=[properties, pages]) as command:
                with patch.object(admission, 'account_processes', return_value=[]):
                    snapshot = host.snapshot()
        self.assertEqual([42], snapshot['registered'])
        self.assertEqual(call('gh', 'api', '--hostname', 'github.com', '--paginate', '--slurp',
                              '/orgs/honua-io/actions/runners?per_page=100'),
                         command.call_args_list[1])

    def test_exclusion_uses_no_stop_now_or_kill(self):
        host = object.__new__(admission.Host)
        host.unit = 'honua-gate-runner@1.service'
        with patch.object(admission, 'command') as command:
            host.exclude()
        self.assertEqual([call('systemctl', 'mask', '--runtime', host.unit),
                          call('systemctl', 'daemon-reload')], command.call_args_list)


class StartupTests(unittest.TestCase):
    def setUp(self):
        self.upstream = Path(__file__).with_name('dockerd-rootless.upstream.sh').read_bytes()

    def test_pin_and_shell_syntax(self):
        self.assertEqual(prepare.UPSTREAM_SHA256, hashlib.sha256(self.upstream).hexdigest())
        source = prepare.render(self.upstream)
        subprocess.run(['sh', '-n'], input=source, text=True, check=True)
        self.assertLess(source.index('python3 ' + prepare.GUARD), source.index('rm -f /run/docker'))
        self.assertEqual(3, source.count('python3 ' + prepare.GUARD))

    def test_state_directory_injection_rejected_before_startup(self):
        source = prepare.render(self.upstream)
        for state in ('canary-state -- /usr/bin/true',
                      '/run/user/1001/dockerd-rootless --detach-netns',
                      '/run/user/../dockerd-rootless', '/tmp/canary',
                      '/run/user/1001*/dockerd-rootless'):
            environment = dict(os.environ, HONUA_ROOTLESS_CANARY_CONFIG='/missing',
                               DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS='', DOCKERD='',
                               DOCKERD_ROOTLESS_ROOTLESSKIT_STATE_DIR=state)
            result = subprocess.run(['sh', '-s'], input=source, text=True, env=environment,
                                    capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual('', result.stdout)

    def test_state_directory_is_constrained_and_quoted(self):
        source = prepare.render(self.upstream)
        self.assertIn('--state-dir="$DOCKERD_ROOTLESS_ROOTLESSKIT_STATE_DIR"', source)
        prefix = source.split('export DOCKERD=/opt/honua-rootless-canary/dockerd-wrapper')[0]
        environment = dict(os.environ, HONUA_ROOTLESS_CANARY_CONFIG='/missing',
                           DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS='', DOCKERD='',
                           DOCKERD_ROOTLESS_ROOTLESSKIT_STATE_DIR='', XDG_RUNTIME_DIR='/run/user/1001')
        result = subprocess.run(['sh', '-s'], input=prefix + '\nprintf "%s" "$DOCKERD_ROOTLESS_ROOTLESSKIT_STATE_DIR"',
                                text=True, env=environment, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('/run/user/1001/dockerd-rootless', result.stdout)

    def test_tampered_source_rejected(self):
        with self.assertRaises(ValueError):
            prepare.render(self.upstream + b'\n')

    def test_conflicting_flags_rejected_before_any_command(self):
        source = prepare.render(self.upstream)
        for flags in ('--detach-netns', '--net=host', '--port-driver=slirp4netns', '--foo'):
            environment = dict(os.environ, HONUA_ROOTLESS_CANARY_CONFIG='/missing',
                               DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS=flags, DOCKERD='')
            result = subprocess.run(['sh', '-s'], input=source, text=True, env=environment,
                                    capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual('', result.stdout)


class ManifestTests(unittest.TestCase):
    def test_present_absent_and_link_roundtrip(self):
        with tempfile.TemporaryDirectory() as directory:
            for kind in ('present', 'absent', 'link'):
                path = Path(directory) / kind
                if kind == 'present':
                    path.write_bytes(b'original\x00data')
                    path.chmod(0o640)
                elif kind == 'link':
                    path.symlink_to('/original-target')
                record = manifest.capture(path)
                path.unlink(missing_ok=True)
                path.write_text('canary')
                manifest.restore(record)
                self.assertEqual(record, manifest.capture(path))

    def test_corrupt_backup_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'file'
            path.write_text('original')
            record = manifest.capture(path)
            record['sha256'] = '0' * 64
            with self.assertRaises(ValueError):
                manifest.restore(record)
            self.assertEqual('original', path.read_text())


if __name__ == '__main__':
    unittest.main()
