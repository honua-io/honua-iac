"""Exercise the installed idle-stop program without host or cloud operations."""

import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "infrastructure/terraform/bootstrap/aws-build-host/install-build-tools.sh"


class BuildHostIdleStopTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        source = re.search(
            r"cat > /usr/local/sbin/honua-build-host-idle-stop <<'PYTHON'\n(.*?)\nPYTHON",
            INSTALLER.read_text(), re.DOTALL,
        )
        self.assertIsNotNone(source, "The installer must ship the idle-stop program")
        script = root / "idle_stop.py"
        script.write_text(source.group(1))
        spec = importlib.util.spec_from_file_location("idle_stop", script)
        self.program = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.program)
        self.program.WORKTREES = root / "wt"
        self.program.WORKTREES.mkdir()
        self.program.LAST_ACTIVE = root / "last_active"
        self.rows = ""
        self.commands = []
        clock = patch.object(self.program.time, "monotonic", return_value=1800)
        clock.start()
        self.addCleanup(clock.stop)
        runner = patch.object(self.program.subprocess, "run", side_effect=self.run_command)
        runner.start()
        self.addCleanup(runner.stop)

    def run_command(self, argv, **kwargs):
        self.commands.append(argv)
        return subprocess.CompletedProcess(argv, 0, stdout=self.rows)

    def shutdowns(self):
        return [command for command in self.commands if command[0] == "shutdown"]

    def test_idle_host_stops_at_thirty_minutes(self):
        self.program.main()
        self.assertEqual(self.shutdowns(), [["shutdown", "-h", "now"]])

    def test_recent_job_gets_the_full_idle_window(self):
        self.program.LAST_ACTIVE.write_text("1")
        self.program.main()
        self.assertEqual(self.shutdowns(), [])

    def test_active_marker_resets_last_activity(self):
        worktree = self.program.WORKTREES / "job"
        worktree.mkdir()
        (worktree / ".honua-active.123").touch()
        self.program.main()
        self.assertEqual(self.shutdowns(), [])
        self.assertEqual(self.program.LAST_ACTIVE.read_text(), "1800")

    def test_running_dotnet_resets_last_activity(self):
        self.rows = "4000 dotnet /home/ubuntu/.dotnet/dotnet test tests.csproj\n"
        self.program.main()
        self.assertEqual(self.shutdowns(), [])
        self.assertEqual(self.program.LAST_ACTIVE.read_text(), "1800")

    def test_docker_builds_prevent_shutdown(self):
        for command in ("docker build .", "docker buildx build .", "docker compose build", "docker compose up --build"):
            with self.subTest(command=command):
                self.rows = f"4000 docker {command}\n"
                self.program.main()
                self.assertEqual(self.shutdowns(), [])

    def test_daemons_and_old_ssh_do_not_hold_idle_host(self):
        self.rows = "4000 dockerd /usr/bin/dockerd\n4000 sshd sshd: ubuntu@notty\n4000 sshd sshd: /usr/sbin/sshd -D [listener]\n"
        self.program.main()
        self.assertEqual(len(self.shutdowns()), 1)

    def test_young_ssh_prevents_shutdown(self):
        self.rows = "1799 sshd sshd: ubuntu@pts/0\n"
        self.program.main()
        self.assertEqual(self.shutdowns(), [])

    def test_ssh_at_thirty_minutes_does_not_hold_idle_host(self):
        self.rows = "1800 sshd sshd: ubuntu@notty\n"
        self.program.main()
        self.assertEqual(len(self.shutdowns()), 1)

    def test_failed_process_inspection_cannot_shutdown(self):
        with patch.object(self.program.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "ps")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.program.main()
        self.assertEqual(self.shutdowns(), [])

    def test_invalid_activity_clock_cannot_shutdown(self):
        self.program.LAST_ACTIVE.write_text("invalid")
        with self.assertRaises(ValueError):
            self.program.main()
        self.assertEqual(self.shutdowns(), [])

    def test_timer_checks_every_five_minutes(self):
        installer = INSTALLER.read_text()
        self.assertIn("OnUnitActiveSec=5min", installer)
        self.assertIn("systemctl enable --now honua-build-host-idle-stop.timer", installer)


if __name__ == "__main__":
    unittest.main()
