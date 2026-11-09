"""Exercise the installed idle-stop program without host or cloud operations."""

import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

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
        self.program.CONFIG = root / "config.json"
        self.program.CONFIG.write_text('{"region":"eu-north-1","group":"honua-lane-build-host","idle_seconds":1800}')
        self.client = Mock()
        sdk = patch.dict("sys.modules", {"boto3": Mock(client=Mock(return_value=self.client))})
        sdk.start()
        self.addCleanup(sdk.stop)
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

    def test_idle_fleet_scales_to_zero(self):
        self.program.main()
        self.client.set_desired_capacity.assert_called_once_with(
            AutoScalingGroupName="honua-lane-build-host", DesiredCapacity=0,
            HonorCooldown=False,
        )
        self.assertFalse(any(command[0] == "shutdown" for command in self.commands))

    def test_failed_scale_down_does_not_shutdown_ec2(self):
        self.client.set_desired_capacity.side_effect = RuntimeError("API unavailable")
        with self.assertRaises(RuntimeError):
            self.program.main()
        self.assertFalse(any(command[0] == "shutdown" for command in self.commands))

    def test_configured_idle_window(self):
        self.program.CONFIG.write_text('{"region":"eu-north-1","group":"honua-lane-build-host","idle_seconds":600}')
        with patch.object(self.program.time, "monotonic", return_value=600):
            self.program.main()
        self.assertEqual(len(self.scale_downs()), 1)

    def scale_downs(self):
        return self.client.set_desired_capacity.call_args_list

    def test_idle_host_stops_at_thirty_minutes(self):
        self.program.main()
        self.assertEqual(len(self.scale_downs()), 1)

    def test_recent_job_gets_the_full_idle_window(self):
        self.program.LAST_ACTIVE.write_text("1")
        self.program.main()
        self.assertEqual(self.scale_downs(), [])

    def test_active_marker_resets_last_activity(self):
        worktree = self.program.WORKTREES / "job"
        worktree.mkdir()
        (worktree / ".honua-active.123").touch()
        self.program.main()
        self.assertEqual(self.scale_downs(), [])
        self.assertEqual(self.program.LAST_ACTIVE.read_text(), "1800")

    def test_running_dotnet_resets_last_activity(self):
        self.rows = "4000 dotnet /home/ubuntu/.dotnet/dotnet test tests.csproj\n"
        self.program.main()
        self.assertEqual(self.scale_downs(), [])
        self.assertEqual(self.program.LAST_ACTIVE.read_text(), "1800")

    def test_docker_builds_prevent_shutdown(self):
        for command in ("docker build .", "docker buildx build .", "docker compose build", "docker compose up --build"):
            with self.subTest(command=command):
                self.program.LAST_ACTIVE.unlink(missing_ok=True)
                self.commands.clear()
                self.client.reset_mock()
                self.rows = f"4000 docker {command}\n"
                self.program.main()
                self.assertEqual(self.scale_downs(), [])
                self.assertEqual(self.program.LAST_ACTIVE.read_text(), "1800")

    def test_buildx_plugin_prevents_shutdown(self):
        self.rows = "4000 docker-buildx /usr/libexec/docker/cli-plugins/docker-buildx buildx build .\n"
        self.program.main()
        self.assertEqual(self.scale_downs(), [])
        self.assertEqual(self.program.LAST_ACTIVE.read_text(), "1800")

    def test_standalone_dotnet_server_does_not_hold_idle_host(self):
        self.rows = "4000 dotnet dotnet /app/Honua.Server.dll\n"
        self.program.main()
        self.assertEqual(len(self.scale_downs()), 1)

    def test_daemons_and_old_ssh_do_not_hold_idle_host(self):
        self.rows = "4000 dockerd /usr/bin/dockerd\n4000 sshd sshd: ubuntu@notty\n4000 sshd sshd: /usr/sbin/sshd -D [listener]\n"
        self.program.main()
        self.assertEqual(len(self.scale_downs()), 1)

    def test_young_ssh_prevents_shutdown(self):
        self.rows = "1799 sshd sshd: ubuntu@pts/0\n"
        self.program.main()
        self.assertEqual(self.scale_downs(), [])

    def test_ssh_at_thirty_minutes_does_not_hold_idle_host(self):
        self.rows = "1800 sshd sshd: ubuntu@notty\n"
        self.program.main()
        self.assertEqual(len(self.scale_downs()), 1)

    def test_failed_process_inspection_cannot_shutdown(self):
        with patch.object(self.program.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "ps")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.program.main()
        self.assertEqual(self.scale_downs(), [])

    def test_invalid_activity_clock_cannot_shutdown(self):
        self.program.LAST_ACTIVE.write_text("invalid")
        with self.assertRaises(ValueError):
            self.program.main()
        self.assertEqual(self.scale_downs(), [])



if __name__ == "__main__":
    unittest.main()
