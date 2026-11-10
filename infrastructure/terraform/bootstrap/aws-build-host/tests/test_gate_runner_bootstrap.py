"""Exercise the real readiness script without installing tools or contacting Docker/AWS."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install-gate-runner.sh"


class RunnerReadinessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        text = INSTALLER.read_text()
        body = re.search(r"<<'CHECK'\n(.*?)\nCHECK\n", text, re.S).group(1)
        self.check = self.root / "check.sh"
        self.check.write_text(body)
        # Only external tools are faked: execute the production shell/control flow
        # and real jq to check Docker's security options, including fail-closed cases.
        stub = self.bin / "stub"
        stub.write_text("""#!/bin/bash
case "${0##*/}" in
  node) [[ "${OLD_NODE:-0}" != 1 ]] ;;
  python3) [[ "${BAD_PYTHON:-0}" != 1 ]] ;;
  locale) echo "${CHARMAP:-UTF-8}" ;;
  date) echo "${ZONE:-UTC}" ;;
  docker)
    if [[ "$1" == info ]]; then
      if [[ "${ROOTFUL:-0}" == 1 ]]; then
        echo '["name=seccomp,profile=builtin"]'
      else
        echo '["name=seccomp,profile=builtin","name=rootless"]'
      fi
    fi ;;
esac
""")
        stub.chmod(0o755)
        tools = "gh python3 pwsh docker git zip unzip curl node npm tar gzip xz zstd timeout openssl locale date"
        for tool in tools.split():
            (self.bin / tool).symlink_to(stub)
        (self.bin / "jq").symlink_to(shutil.which("jq"))
        self.sdk = self.root / "sdk"
        self.cache = self.root / "cache"
        self.sdk.mkdir()
        self.cache.mkdir()

    def run_check(self, soft_limit=65536, **overrides):
        env = dict(os.environ, PATH=str(self.bin), DOTNET_INSTALL_DIR=str(self.sdk),
                   RUNNER_TOOL_CACHE=str(self.cache), **overrides)
        return subprocess.run(
            ["/bin/bash", "-c", 'ulimit -n "$1"; exec /bin/bash "$2"',
             "check", str(soft_limit), str(self.check)],
            env=env, capture_output=True, text=True, timeout=10,
        )

    def test_ready_image_is_accepted(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_admission_cli_is_rejected(self):
        (self.bin / "gh").unlink()
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_incompatible_node_is_rejected(self):
        self.assertNotEqual(self.run_check(OLD_NODE="1").returncode, 0)

    def test_missing_python_dependency_is_rejected(self):
        self.assertNotEqual(self.run_check(BAD_PYTHON="1").returncode, 0)

    def test_rootful_engine_is_rejected(self):
        self.assertNotEqual(self.run_check(ROOTFUL="1").returncode, 0)

    def test_missing_sdk_directory_is_rejected(self):
        self.sdk.rmdir()
        self.assertNotEqual(self.run_check().returncode, 0)

    def test_incompatible_locale_is_rejected(self):
        self.assertNotEqual(self.run_check(CHARMAP="ANSI_X3.4-1968").returncode, 0)

    def test_incompatible_timezone_is_rejected(self):
        self.assertNotEqual(self.run_check(ZONE="HST").returncode, 0)

    def test_low_open_file_limit_is_rejected(self):
        self.assertNotEqual(self.run_check(soft_limit=1024).returncode, 0)

    def test_failed_readiness_prevents_registration(self):
        body = re.search(r"<<'PREPARE'\n(.*?)\nPREPARE\n", INSTALLER.read_text(), re.S).group(1)
        sequence = body.rsplit("\nend_previous_job\n", 1)[1]
        script = """set -euo pipefail
restore_pristine_home() { :; }
block_instance_metadata() { :; }
check_prerequisites() { return 1; }
register_for_one_job() { echo REGISTERED; }
""" + sequence
        result = subprocess.run(["/bin/bash"], input=script, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("REGISTERED", result.stdout)

    def test_embedded_shell_scripts_parse(self):
        bodies = re.findall(r"<<'(PREPARE|RUN|ENVIRONMENT|CHECK|HEARTBEAT)'\n(.*?)\n\1\n", INSTALLER.read_text(), re.S)
        self.assertEqual(len(bodies), 5)
        for name, body in bodies:
            with self.subTest(script=name):
                result = subprocess.run(["/bin/bash", "-n"], input=body, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
