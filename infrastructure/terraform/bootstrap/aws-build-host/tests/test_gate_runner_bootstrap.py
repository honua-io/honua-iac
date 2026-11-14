"""Exercise the real readiness script without installing tools or contacting Docker/AWS."""

import json
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
        sequence = body.rsplit("\nend_previous_job\n", 1)[1].replace(
            '/usr/local/sbin/honua-gate-runner-registration register "$index"',
            "register_for_one_job",
        )
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
        bodies = re.findall(r"<<'(PREPARE|RUN|ENVIRONMENT|CHECK|HEARTBEAT|REGISTRATION|SPOT)'\n(.*?)\n\1\n", INSTALLER.read_text(), re.S)
        self.assertEqual(len(bodies), 7)
        for name, body in bodies:
            with self.subTest(script=name):
                result = subprocess.run(["/bin/bash", "-n"], input=body, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)


def deletions(requests):
    return [request for request in requests if '/actions/runners/' in request and 'generate-jitconfig' not in request]


class RunnerRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "jq").symlink_to(shutil.which("jq"))
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps({"org": "test-org", "runners": [
            {"pool": "gate", "group": "gate", "labels": ["honua-build"]},
            {"pool": "heavy", "group": "heavy", "labels": ["honua-heavy"]},
        ]}))
        self.log = self.root / "requests"
        self.state = self.root / "state"
        self.state.mkdir()
        body = re.search(r"<<'REGISTRATION'\n(.*?)\nREGISTRATION\n", INSTALLER.read_text(), re.S).group(1)
        # Authentication is unchanged; exercise lifecycle/API calls without live credentials.
        start = body.index('secrets="$(mktemp')
        end = body.index('\ncase "$mode" in', start)
        body = body[:start] + (
            'secrets="$TEST_ROOT"\n'
            'group_id_named() { case "$1" in gate) echo 42 ;; heavy) [[ -n "${NO_HEAVY_GROUP:-}" ]] || echo 43 ;; esac; }\n'
        ) + body[end:]
        body = body.replace('/etc/honua-gate-runner.json', str(self.config))
        body = body.replace('/run/honua-gate-runner-state', str(self.state))
        body = body.replace('/run/honua-gate-runner/', str(self.root / 'runtime') + '/')
        install = self.bin / "install"
        install.write_text('#!/bin/bash\nargs=(); while (($#)); do case "$1" in -o|-g) shift 2;; *) args+=("$1"); shift;; esac; done\nexec /usr/bin/install "${args[@]}"\n')
        install.chmod(0o755)
        self.script = self.root / "registration.sh"
        self.script.write_text(body)
        curl = self.bin / "curl"
        curl.write_text(r"""#!/usr/bin/python3
import json, os, pathlib, sys
args = sys.argv[1:]
url = args[-1]
root = pathlib.Path(os.environ['TEST_ROOT'])
with (root / 'requests').open('a') as log: log.write(url + '\n')
if '-X' in args and args[args.index('-X') + 1] == 'DELETE':
    print(os.environ.get('DELETE_STATUS', '204'), end='')
    sys.exit(0)
if url.endswith('/latest/api/token'):
    print('token'); sys.exit(0)
if url.endswith('/latest/meta-data/instance-id'):
    print('i-abc123'); sys.exit(0)
if url.endswith('/generate-jitconfig'):
    (root / 'jit-request').write_text(args[args.index('-d') + 1])
    print(json.dumps({'runner': {'id': json.loads(os.environ.get('RUNNER_ID', '123'))},
                      'encoded_jit_config': 'test-jit'})); sys.exit(0)
page = root / (('heavy-page-' if '/runner-groups/43/' in url else 'page-') + url.rsplit('page=', 1)[-1])
print(page.read_text() if page.exists() else '{"runners": []}')
""")
        curl.chmod(0o755)

    def runner(self, number, **overrides):
        return dict(id=number, name=f"i-abc123-1-{number}", status="offline", busy=False, **overrides)

    def run_script(self, mode, index="1", **overrides):
        result = subprocess.run(
            ["/bin/bash", str(self.script), mode, index],
            env=dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin", TEST_ROOT=str(self.root), **overrides),
            text=True, capture_output=True, timeout=10,
        )
        requests = self.log.read_text().splitlines() if self.log.exists() else []
        return result, requests

    def page(self, number, runners):
        (self.root / f"page-{number}").write_text(json.dumps({"runners": runners}))

    def test_prune_only_offline_owned_idle_runners_in_group(self):
        self.page(1, [self.runner(1), dict(self.runner(2), status="online"),
                      dict(self.runner(3), busy=True), dict(self.runner(4), name="other-runner")])
        result, requests = self.run_script("prune")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/runner-groups/42/runners?', requests[0])
        self.assertEqual(deletions(requests), ['https://api.github.com/orgs/test-org/actions/runners/1'])

    def test_collects_all_pages_before_deletion(self):
        self.page(1, [self.runner(1)] + [dict(self.runner(i), status="online") for i in range(2, 101)])
        self.page(2, [self.runner(101)])
        result, requests = self.run_script("prune")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('page=2', requests[1])
        self.assertEqual(deletions(requests), ['https://api.github.com/orgs/test-org/actions/runners/1',
                                               'https://api.github.com/orgs/test-org/actions/runners/101'])

    def test_prune_delete_failure_does_not_block_other_cleanup(self):
        self.page(1, [self.runner(1), self.runner(2)])
        result, requests = self.run_script('prune', DELETE_STATUS='422')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(deletions(requests)[-1].endswith('/2'))
        self.assertIn('Could not remove offline runner', result.stderr)

    def test_register_records_id_and_installs_jitconfig(self):
        result, requests = self.run_script('register')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.state / '1').read_text(), '123\n')
        self.assertEqual((self.root / 'runtime/1/jitconfig').read_text(), 'test-jit\n')
        self.assertTrue(requests[-1].endswith('/generate-jitconfig'))

    def test_register_uses_its_own_pool_group_and_labels(self):
        result, _ = self.run_script('register', index="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        request = json.loads((self.root / 'jit-request').read_text())
        self.assertEqual(request["runner_group_id"], 43)
        self.assertEqual(request["labels"], ["honua-heavy"])
        self.assertTrue(request["name"].startswith("i-abc123-2-"))

    def test_register_fails_when_its_group_is_missing(self):
        result, requests = self.run_script('register', index="2", NO_HEAVY_GROUP="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state / '2').exists())
        self.assertFalse(any(r.endswith('/generate-jitconfig') for r in requests))

    def test_prune_covers_every_runner_group(self):
        self.page(1, [self.runner(1)])
        (self.root / "heavy-page-1").write_text(json.dumps({"runners": [self.runner(7)]}))
        result, requests = self.run_script("prune")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(deletions(requests),
                         ['https://api.github.com/orgs/test-org/actions/runners/1',
                          'https://api.github.com/orgs/test-org/actions/runners/7'])

    def test_prune_skips_a_missing_group_and_cleans_the_others(self):
        self.page(1, [self.runner(1)])
        result, requests = self.run_script("prune", NO_HEAVY_GROUP="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Runner group heavy does not exist", result.stderr)
        self.assertEqual(deletions(requests), ['https://api.github.com/orgs/test-org/actions/runners/1'])

    def test_register_rejects_missing_numeric_id_without_state(self):
        result, _ = self.run_script('register', RUNNER_ID='null')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.state / '1').exists())

    def test_remove_recorded_id_and_clear_state(self):
        (self.state / '1').write_text('123')
        result, requests = self.run_script('remove')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(requests[-1].endswith('/123'))
        self.assertFalse((self.state / '1').exists())

    def test_already_removed_registration_is_success(self):
        (self.state / '1').write_text('123')
        result, _ = self.run_script('remove', DELETE_STATUS='404')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.state / '1').exists())

    def test_failed_delete_preserves_state_for_retry(self):
        (self.state / '1').write_text('123')
        result, _ = self.run_script('remove', DELETE_STATUS='403')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.state / '1').exists())

    def test_missing_registration_does_not_authenticate(self):
        result, requests = self.run_script('remove')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, [])


class SpotNoticeTests(unittest.TestCase):
    def run_notice(self, status):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            body = re.search(r"<<'SPOT'\n(.*?)\nSPOT\n", INSTALLER.read_text(), re.S).group(1)
            body = body.replace("/run/honua-gate-runner-draining", str(root / "draining"))
            (root / "notice").write_text(body)
            for tool, script in {
                "curl": '#!/bin/bash\nif [[ "$*" == *instance-action* ]]; then echo "$STATUS"; else echo token; fi\n',
                "jq": '#!/bin/bash\necho 2\n',
                "systemctl": '#!/bin/bash\necho "$*" >> "$CALLS"\n',
            }.items():
                path = root / tool
                path.write_text(script)
                path.chmod(0o755)
            calls = root / "calls"
            result = subprocess.run(["/bin/bash", str(root / "notice")],
                                    env=dict(os.environ, PATH=f"{root}:/usr/bin:/bin",
                                             STATUS=status, CALLS=str(calls)),
                                    capture_output=True, text=True, timeout=10)
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_no_notice_keeps_runners_running(self):
        result, calls = self.run_notice("404")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_notice_stops_heartbeat_then_both_runners(self):
        result, calls = self.run_notice("200")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            "stop honua-gate-runner-heartbeat.timer honua-gate-runner-heartbeat.service",
            "stop honua-gate-runner@1.service honua-gate-runner@2.service",
        ])

    def test_service_wires_boot_cleanup_and_privileged_exit_cleanup(self):
        text = INSTALLER.read_text()
        self.assertIn("Wants=honua-gate-runner-prune.service", text)
        self.assertNotIn("Requires=honua-gate-runner-prune.service", text)
        self.assertIn("After=network-online.target honua-gate-runner-prune.service", text)
        self.assertIn("ExecStopPost=+/usr/local/sbin/honua-gate-runner-registration remove %i", text)


if __name__ == "__main__":
    unittest.main()
