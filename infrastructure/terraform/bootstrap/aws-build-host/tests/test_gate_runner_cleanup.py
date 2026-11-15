"""Check cleanup boundaries; opt-in integration uses isolated transient systemd units."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest
import uuid


INSTALLER = Path(__file__).resolve().parents[1] / "install-gate-runner.sh"


def cleanup_function():
    source = INSTALLER.read_text()
    return re.search(r"^end_previous_job\(\) \{\n.*?^\}", source, re.M | re.S).group(0)


class CleanupContractTests(unittest.TestCase):
    def test_cleanup_stops_only_the_rootless_manager(self):
        body = cleanup_function()
        self.assertIn('systemctl stop "user@${uid}.service"', body)
        self.assertNotRegex(body, r"\b(?:pkill|killall|loginctl)\b")
        self.assertNotIn('systemctl stop "user-${uid}.slice"', body)

    def test_both_process_owners_have_control_group_cleanup(self):
        source = INSTALLER.read_text()
        unit = re.search(r"cat > /etc/systemd/system/honua-gate-runner@.service <<'SERVICE'\n(.*?)\nSERVICE", source, re.S).group(1)
        self.assertIn("KillMode=control-group", unit)
        self.assertIn('user@${uid}.service.d/50-gate-runner-cleanup.conf', source)
        self.assertIn("printf '[Service]\\nKillMode=control-group\\n'", source)
        self.assertIn("ExecStartPre=+/usr/local/sbin/honua-gate-runner-prepare %i", unit)
        self.assertIn("ExecStopPost=+/usr/local/sbin/honua-gate-runner-prepare %i --clean", unit)

    def test_prepare_is_replaced_atomically_for_running_jobs(self):
        source = INSTALLER.read_text()
        self.assertIn('mktemp /usr/local/sbin/.honua-gate-runner-prepare.XXXXXX', source)
        self.assertIn('mv -f "$prepare_file" /usr/local/sbin/honua-gate-runner-prepare', source)
        self.assertNotIn("cat > /usr/local/sbin/honua-gate-runner-prepare", source)


@unittest.skipUnless(os.environ.get("HONUA_SYSTEMD_CGROUP_TEST") == "1", "requires opt-in root systemd fixture")
class CleanupCgroupTests(unittest.TestCase):
    def setUp(self):
        self.assertEqual(os.geteuid(), 0, "run the opt-in fixture as root")
        self.root = Path(tempfile.mkdtemp(prefix="honua-cleanup-test-"))
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.root)], check=True))
        self.root.chmod(0o755)
        self.prefix = "honua-cleanup-test-" + uuid.uuid4().hex
        self.account = "hcgt-" + self.prefix[-16:]
        subprocess.run(["useradd", "--system", "--no-create-home", "--user-group", self.account],
                       check=True, capture_output=True, timeout=10)
        self.addCleanup(lambda: subprocess.run(["userdel", self.account], check=True, capture_output=True, timeout=10))
        self.uid = int(subprocess.check_output(["id", "-u", self.account], text=True))
        self.units = {name: f"{self.prefix}-{name}.service" for name in ("manager", "runner", "foreign")}
        self.addCleanup(self.remove_units)
        self.script = self.root / "cleanup.sh"
        # Redirect only the manager's name and filesystem cleanup. Process signals
        # and the service lifecycle use the real kernel/systemd and the real UID.
        self.script.write_text(f'''#!/bin/bash
set -euo pipefail
uid={self.uid}
user={self.uid}
systemctl() {{
  [[ "$*" == "stop user@${{uid}}.service" ]] || return 91
  /usr/bin/systemctl stop {self.units['manager']}
}}
grep() {{ printf 'fixture:1000000:65536\\n'; }}
find() {{ :; }}
{cleanup_function()}
end_previous_job
''')
        self.script.chmod(0o700)

    def remove_units(self):
        subprocess.run(["systemctl", "stop", *self.units.values()], capture_output=True, timeout=30)
        subprocess.run(["systemctl", "reset-failed", *self.units.values()], capture_output=True, timeout=10)

    def start_unit(self, name):
        properties = [f"User={self.uid}", f"Group={self.uid}", "KillMode=control-group", "TimeoutStopSec=5"]
        if name == "runner":
            properties += [f"ExecStartPre=+{self.script}", f"ExecStopPost=+{self.script}"]
        command = ["systemd-run", "--quiet", "--unit=" + self.units[name]]
        for value in properties:
            command += ["--property=" + value]
        result = subprocess.run(command + ["/bin/sleep", "infinity"], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.pid(name)

    def pid(self, name):
        result = subprocess.run(["systemctl", "show", "--value", "-p", "MainPID", self.units[name]],
                                check=True, capture_output=True, text=True, timeout=10)
        return int(result.stdout.strip())

    def assert_running(self, pid):
        # systemd-executor publishes MainPID before it drops credentials and
        # execs the command. During that window /proc shows a root "(sleep)"
        # in uninterruptible exec, so wait for the service uid at rest.
        uid_pattern = rf"(?m)^Uid:\s+{self.uid}\s+{self.uid}\s"
        state_pattern = r"(?m)^State:\s+[SR]"
        deadline = time.monotonic() + 2
        status = ""
        while time.monotonic() < deadline:
            status = Path(f"/proc/{pid}/status").read_text()
            if re.search(uid_pattern, status) and re.search(state_pattern, status):
                return
            time.sleep(0.02)
        self.assertRegex(status, uid_pattern)
        self.assertRegex(status, state_pattern)

    def test_same_uid_foreign_cgroup_survives_start_and_stop(self):
        foreign = self.start_unit("foreign")
        previous_manager = self.start_unit("manager")
        runner = self.start_unit("runner")
        self.assert_running(foreign)
        self.assert_running(runner)
        self.assertFalse(Path(f"/proc/{previous_manager}").exists())
        next_manager = self.start_unit("manager")
        groups = [Path(f"/proc/{pid}/cgroup").read_text() for pid in (foreign, runner, next_manager)]
        self.assertEqual(len(set(groups)), 3)
        subprocess.run(["systemctl", "stop", self.units["runner"]], check=True, capture_output=True, timeout=15)
        self.assertFalse(Path(f"/proc/{runner}").exists())
        self.assertFalse(Path(f"/proc/{next_manager}").exists())
        self.assert_running(foreign)


if __name__ == "__main__":
    unittest.main()
