"""Offline coverage of evidence collection when startup or AWS reads fail."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/capture-task-diagnostics.py"
SPEC = importlib.util.spec_from_file_location("diagnostics", SCRIPT)
diagnostics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(diagnostics)


class DiagnosticsTests(unittest.TestCase):
    def test_retains_stopped_tasks_exit_code_and_container_logs(self):
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            if "list-tasks" in command:
                value = {"taskArns": ["arn:task:stopped"] if "STOPPED" in command else []}
            elif "describe-tasks" in command:
                value = {"tasks": [{"stoppedReason": "Essential container exited",
                                    "containers": [{"exitCode": 1, "reason": "startup failed"}]}]}
            elif "filter-log-events" in command:
                value = {"events": [{"message": "KeyRingCertificatePath is required"}]}
            else:
                value = {"services": [{"events": [{"message": "no healthy targets"}]}]}
            return subprocess.CompletedProcess(command, 0, json.dumps(value), "")

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "evidence"
            result = diagnostics.capture("cluster", ["primary", "canary"], "/honua/cell", output, "us-east-1", run)
            self.assertTrue(result["complete"])
            self.assertEqual(0o700, output.stat().st_mode & 0o777)
            details = json.loads((output / "service-0-stopped-details-0.json").read_text())
            self.assertEqual(1, details["tasks"][0]["containers"][0]["exitCode"])
            self.assertIn("KeyRingCertificatePath", (output / "container-logs.json").read_text())
            self.assertEqual(2, sum("describe-tasks" in command for command in calls))
            self.assertFalse(any("get-secret-value" in command or "describe-task-definition" in command for command in calls))

    def test_partial_collection_keeps_logs_and_reports_read_failure(self):
        def run(command, **kwargs):
            if "list-tasks" in command:
                raise subprocess.TimeoutExpired(command, 60)
            if "describe-services" in command:
                return subprocess.CompletedProcess(command, 1, "", "AccessDenied")
            return subprocess.CompletedProcess(command, 0, '{"events":[{"message":"startup failed"}]}', "")

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "evidence"
            result = diagnostics.capture("cluster", ["primary"], "/honua/cell", output, "us-east-1", run)
            self.assertFalse(result["complete"])
            self.assertEqual(["services", "service-0-stopped", "service-0-running"], result["failed_collections"])
            self.assertEqual("AccessDenied", (output / "services.stderr.txt").read_text())
            self.assertIn("startup failed", (output / "container-logs.json").read_text())


if __name__ == "__main__":
    unittest.main()
