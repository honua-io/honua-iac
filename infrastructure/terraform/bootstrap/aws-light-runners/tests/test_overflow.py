"""Exercise admission and private-daemon cleanup without SSH, Docker or AWS."""
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class OverflowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.home = Path(self.directory.name)
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.home}:{os.environ['PATH']}")
        self.stub("id", "echo gate-runner-16")
        self.stub("df", 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\\nmock 99999999 0 ${FREE_KIB:-99999999} 0%% /\\n"')
        self.stub("docker", 'echo "$*" >> "$HOME/docker.log"; if [[ "$1" == ps ]]; then echo "${CONTAINERS:-}"; fi; exit "${DOCKER_STATUS:-0}"')
        self.scripts = {}
        for name in ("pre-pr-admit.sh", "pre-pr-exec.sh", "pre-pr-session.sh"):
            text = (ROOT / name).read_text().replace(". /etc/honua-gate-runner-env", ":")
            text = text.replace("/run/honua-gate-runner-draining", str(self.home / "draining"))
            text = text.replace("/usr/local/bin/honua-pre-pr-admit", str(self.home / "pre-pr-admit.sh"))
            target = self.home / name
            target.write_text(text)
            target.chmod(0o755)
            self.scripts[name] = str(target)

    def stub(self, name, text):
        target = self.home / name
        target.write_text("#!/bin/bash\n" + text + "\n")
        target.chmod(0o755)

    def execute(self, *command):
        return subprocess.run(["bash", self.scripts["pre-pr-exec.sh"], *command], env=self.env, capture_output=True, text=True, timeout=5)

    def session(self):
        return subprocess.Popen(["bash", self.scripts["pre-pr-session.sh"]], env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_installer_creates_private_temp_root_for_new_and_existing_accounts(self):
        installer = (ROOT / "install-pre-pr-overflow.sh").read_text()
        directories = re.search(r'install -d -o "\$overflow_user".*?\n([^\n]+)', installer).group(0)
        directories = directories.replace('-o "$overflow_user" -g "$overflow_user"', "")
        environment = (ROOT.parent / "aws-build-host/install-gate-runner.sh").read_text()
        environment = re.search(r"<<'ENVIRONMENT'\n(.*?)\nENVIRONMENT\n", environment, re.S).group(1)
        for _ in range(2):
            result = subprocess.run(
                ["bash", "-c", directories + "\n" + environment + '\nmktemp "$TMPDIR/overflow.XXXXXX"'],
                env=dict(os.environ, HOME=str(self.home), overflow_home=str(self.home)),
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            temporary = self.home / ".cache/tmp"
            self.assertEqual(Path(result.stdout.strip()).parent, temporary)
            self.assertEqual(temporary.stat().st_mode & 0o777, 0o700)

    def test_session_lock_spans_sync_and_releases_at_eof(self):
        first = self.session()
        try:
            self.assertEqual(first.stdout.readline(), "HONUA_OVERFLOW_ADMITTED\n")
            second = self.session()
            out, _ = second.communicate(timeout=5)
            self.assertEqual(second.returncode, 75)
            self.assertEqual(out, "")
        finally:
            first.communicate(timeout=5)
        third = self.session()
        out, _ = third.communicate(timeout=5)
        self.assertEqual(third.returncode, 0)
        self.assertEqual(out, "HONUA_OVERFLOW_ADMITTED\n")

    def test_disconnected_admission_waits_for_running_executor(self):
        first = self.session()
        workload = None
        try:
            self.assertEqual(first.stdout.readline(), "HONUA_OVERFLOW_ADMITTED\n")
            workload = subprocess.Popen(
                ["bash", self.scripts["pre-pr-exec.sh"], "bash", "-c", 'echo running; read -r release'],
                env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertEqual(workload.stdout.readline(), "running\n")
            first.stdin.close()
            first.stdin = None
            with self.assertRaises(subprocess.TimeoutExpired):
                first.wait(timeout=0.2)
            second = self.session()
            out, _ = second.communicate(timeout=5)
            self.assertEqual((second.returncode, out), (75, ""))
        finally:
            if workload is not None:
                workload.communicate("release\n", timeout=5)
            first.communicate(timeout=5)
        third = self.session()
        out, _ = third.communicate(timeout=5)
        self.assertEqual((third.returncode, out), (0, "HONUA_OVERFLOW_ADMITTED\n"))

    def test_low_disk_refuses_before_admission(self):
        self.env["FREE_KIB"] = "1024"
        session = self.session()
        out, _ = session.communicate(timeout=5)
        self.assertEqual(session.returncode, 75)
        self.assertEqual(out, "")

    def test_draining_refuses_before_admission(self):
        (self.home / "draining").touch()
        session = self.session()
        out, _ = session.communicate(timeout=5)
        self.assertEqual(session.returncode, 75)
        self.assertEqual(out, "")

    def test_executor_rechecks_after_session_admission(self):
        for reason in ("draining", "disk"):
            with self.subTest(reason=reason):
                session = self.session()
                try:
                    self.assertEqual(session.stdout.readline(), "HONUA_OVERFLOW_ADMITTED\n")
                    if reason == "draining":
                        (self.home / "draining").touch()
                    else:
                        self.env["FREE_KIB"] = "1024"
                    result = self.execute("touch", str(self.home / "executed"))
                    self.assertEqual(result.returncode, 75)
                    self.assertFalse((self.home / "executed").exists())
                finally:
                    session.communicate(timeout=5)
                    (self.home / "draining").unlink(missing_ok=True)
                    self.env.pop("FREE_KIB", None)

    def test_workload_status_is_preserved_including_75(self):
        for status in (0, 1, 75):
            with self.subTest(status=status):
                result = self.execute("bash", "-c", f"exit {status}")
                self.assertEqual(result.returncode, status, result.stderr)

    def test_workload_has_four_cpu_budget(self):
        result = self.execute("bash", "-c", 'echo "$DOTNET_PROCESSOR_COUNT:$HONUA_STAGE0_MAX_CPU_COUNT"')
        self.assertEqual(result.stdout, "4:4\n")

    def test_stale_and_current_containers_removed_under_lock(self):
        self.env["CONTAINERS"] = "abc def"
        result = self.execute("true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / "docker.log").read_text().splitlines(), ["ps -aq", "rm -f abc def", "ps -aq", "rm -f abc def"])

    def test_unhealthy_daemon_prevents_workload(self):
        self.env["DOCKER_STATUS"] = "1"
        result = self.execute("touch", str(self.home / "executed"))
        self.assertEqual(result.returncode, 75)
        self.assertFalse((self.home / "executed").exists())

    def test_cleanup_failure_reports_separately_from_workload_status(self):
        self.stub("docker", 'if [[ -e "$HOME/workload-finished" ]]; then exit 1; fi')
        for status in (0, 1, 75):
            with self.subTest(status=status):
                (self.home / "workload-finished").unlink(missing_ok=True)
                result = self.execute("bash", "-c", f'touch "$HOME/workload-finished"; exit {status}')
                self.assertEqual(result.returncode, status)
                self.assertIn("Overflow container cleanup failed", result.stderr)

    def test_wrong_account_refused(self):
        self.stub("id", "echo ubuntu")
        result = self.execute("true")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
