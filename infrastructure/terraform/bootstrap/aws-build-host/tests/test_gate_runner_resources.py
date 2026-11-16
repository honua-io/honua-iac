"""Execute the production resource generator against per-slot configurations."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install-gate-runner.sh"


class RunnerResourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "runners.json"
        self.config.write_text(json.dumps({"runners": [
            {"memory_max_gib": 5, "cpu_quota_percent": 250},
            {"memory_max_gib": 16, "cpu_quota_percent": 800},
            {"memory_max_gib": 2, "cpu_quota_percent": 100},
        ]}))
        source = INSTALLER.read_text()
        match = re.search(r"(runner_resource_environment\(\) \{\n.*?\n\})", source, re.S)
        self.assertIsNotNone(match)
        self.generator = self.root / "resources.sh"
        self.generator.write_text("set -euo pipefail\n" + match.group(1) +
                                  '\nrunner_resource_environment "$1"\n')

    def resource_environment(self, index):
        result = subprocess.run(
            ["/bin/bash", str(self.generator), str(index)],
            env=dict(os.environ, gate_config=str(self.config)),
            capture_output=True, text=True, check=True, timeout=5,
        )
        section, assignment = result.stdout.strip().splitlines()
        self.assertEqual(section, "[Service]")
        return dict(item.split("=", 1) for item in shlex.split(assignment.removeprefix("Environment=")))

    def test_light_slot_reserves_memory_and_rounds_fractional_cpu_down(self):
        self.assertEqual(self.resource_environment(1), {"CODEQL_RAM": "3072", "CODEQL_THREADS": "2"})

    def test_each_slot_uses_its_own_configuration(self):
        self.assertEqual(self.resource_environment(2), {"CODEQL_RAM": "9830", "CODEQL_THREADS": "8"})
        self.assertEqual(self.resource_environment(3), {"CODEQL_RAM": "1228", "CODEQL_THREADS": "1"})

    def test_bootstrap_writes_budget_to_the_matching_runner_service(self):
        self.assertIn(
            'runner_resource_environment "$index" > "/etc/systemd/system/'
            'honua-gate-runner@${index}.service.d/55-codeql-resources.conf"',
            INSTALLER.read_text(),
        )


if __name__ == "__main__":
    unittest.main()
