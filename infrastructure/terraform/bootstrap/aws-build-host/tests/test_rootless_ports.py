"""Run the generated daemon wrapper without installing or starting Docker."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install-gate-runner.sh"
PORT_RANGE = Path("/proc/sys/net/ipv4/ip_local_port_range")


class RootlessPortTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.body = re.search(r"<<'DOCKERD'\n(.*?)\nDOCKERD\n", INSTALLER.read_text(), re.S).group(1)
        recorder = self.root / "record.py"
        recorder.write_text(
            "import json, pathlib, sys\n"
            "print(json.dumps({'ports': pathlib.Path('/proc/sys/net/ipv4/ip_local_port_range').read_text(), "
            "'args': sys.argv[1:]}))\n"
        )
        self.body = self.body.replace(
            'exec /usr/bin/dockerd "$@"',
            f'exec /usr/bin/python3 {shlex.quote(str(recorder))} "$@"',
        )
        self.script = self.root / "dockerd.sh"
        self.script.write_text(self.body)

    def run_wrapper(self, *args, namespace=None, **overrides):
        env = dict(os.environ, HONUA_RUNNER_INDEX="1", _DOCKERD_ROOTLESS_CHILD="1",
                   DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS="false")
        env.update(overrides)
        command = ["/bin/bash", str(self.script), *args]
        if namespace:
            command = ["unshare", "--user", "--map-root-user", *namespace, *command]
        return subprocess.run(command, env=env, capture_output=True, text=True, timeout=10)

    def require_user_namespace(self):
        result = subprocess.run(
            ["unshare", "--user", "--map-root-user", "--net", "true"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode:
            self.skipTest(f"Unprivileged namespaces unavailable: {result.stderr.strip()}")

    def test_generated_wrapper_parses(self):
        result = subprocess.run(["/bin/bash", "-n", str(self.script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_runner_indices_fail_before_daemon(self):
        for index in ("", "0", "17", "01", "-1", "1+1", "1;true"):
            with self.subTest(index=index):
                result = self.run_wrapper(HONUA_RUNNER_INDEX=index)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("runner index", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_parent_process_is_rejected(self):
        result = self.run_wrapper(_DOCKERD_ROOTLESS_CHILD="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rootless child", result.stderr)

    def test_initial_user_namespace_is_rejected(self):
        before = PORT_RANGE.read_text()
        result = self.run_wrapper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rootless user mapping", result.stderr)
        self.assertEqual(PORT_RANGE.read_text(), before)

    def test_detached_network_mode_is_rejected(self):
        for value in ("", "true", "1"):
            with self.subTest(mode=value):
                result = self.run_wrapper(DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("attached child network namespace", result.stderr)

    def test_host_ephemeral_overlap_is_rejected(self):
        fixture = self.root / "host-range"
        self.script.write_text(self.body.replace(str(PORT_RANGE), str(fixture)))
        for value in ("20000 21000", "10000 20000", "32287 60000", "10000 60000"):
            with self.subTest(ports=value):
                fixture.write_text(value + "\n")
                result = self.run_wrapper("--check-host")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("overlap", result.stderr)
        for value in ("32768 60999", "10000 19999", "32288 60999"):
            with self.subTest(ports=value):
                fixture.write_text(value + "\n")
                self.assertEqual(self.run_wrapper("--check-host").returncode, 0)

    def test_sysctl_cannot_modify_host_network_from_child_user_namespace(self):
        self.require_user_namespace()
        before = PORT_RANGE.read_text()
        result = self.run_wrapper(namespace=["--"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("permission denied", result.stderr.lower())
        self.assertEqual(result.stdout, "")
        self.assertEqual(PORT_RANGE.read_text(), before)

    def test_sixteen_real_network_namespaces_have_disjoint_ranges(self):
        self.require_user_namespace()
        before = PORT_RANGE.read_text()
        allocated = set()
        for index in range(1, 17):
            result = self.run_wrapper("--debug", namespace=["--net"], HONUA_RUNNER_INDEX=str(index))
            self.assertEqual(result.returncode, 0, result.stderr)
            observation = json.loads(result.stdout)
            first, last = map(int, observation["ports"].split())
            self.assertEqual((first, last), (20000 + (index - 1) * 768, 19999 + index * 768))
            self.assertEqual(observation["args"], ["--debug"])
            ports = set(range(first, last + 1))
            self.assertFalse(ports & allocated)
            allocated.update(ports)
        self.assertEqual(len(allocated), 12288)
        self.assertEqual(PORT_RANGE.read_text(), before)

    def test_dropin_is_installed_in_pristine_home(self):
        text = INSTALLER.read_text()
        function = re.search(r"configure_rootless_ports\(\) \{\n.*?\n\}", text, re.S).group(0)
        result = subprocess.run(
            ["/bin/bash", "-c", function + '\nconfigure_rootless_ports "$1" 7', "configure", str(self.root)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        contents = (self.root / ".config/systemd/user/docker.service.d/50-honua-ports.conf").read_text()
        self.assertIn('Environment="HONUA_RUNNER_INDEX=7"', contents)
        self.assertIn('Environment="DOCKERD=/usr/local/bin/honua-gate-dockerd"', contents)
        self.assertIn('Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=false"', contents)
        self.assertLess(text.index('configure_rootless_ports "/home/${user}"'),
                        text.index("dockerd-rootless-setuptool.sh install"))
        self.assertIn('configure_rootless_ports "/var/lib/honua-gate-runner/home-${index}" "$index"', text)


if __name__ == "__main__":
    unittest.main()
