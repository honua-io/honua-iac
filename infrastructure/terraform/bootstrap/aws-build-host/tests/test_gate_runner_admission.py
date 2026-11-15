"""Exercise the real job admission hook and its wiring into the runner start wrapper."""

import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install-gate-runner.sh"
HOOK = "/usr/local/bin/honua-gate-runner-admit.sh"
REPOSITORY = "honua-io/honua-server"
# The runner's worker starts the hook as a direct child and runs the job's steps afterwards.
# This stands in for it: the marker is what a later step would be.
WORKER = '/bin/bash --noprofile --norc -e -o pipefail "$1" && echo hook-passed || echo hook-failed; echo WORKER-CONTINUED'


def embedded(name):
    match = re.search(rf"<<'{name}'\n(.*?)\n{name}\n", INSTALLER.read_text(), re.S)
    if match is None:
        raise AssertionError(f"the installer has no {name} script")
    return match.group(1)


def pull_request(head):
    return {"action": "synchronize", "pull_request": {"head": {"repo": head}},
            "repository": {"full_name": REPOSITORY}}


class JobAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.hook = self.root / "admit.sh"
        self.hook.write_text(embedded("ADMIT"))

    def environment(self, event, repository=REPOSITORY, **overrides):
        env = {"PATH": "/usr/bin:/bin"}
        if repository is not None:
            env["GITHUB_REPOSITORY"] = repository
        if event is not None:
            path = self.root / "event.json"
            path.write_text(event if isinstance(event, str) else json.dumps(event))
            env["GITHUB_EVENT_PATH"] = str(path)
        env.update(overrides)
        return env

    def admit(self, event, repository=REPOSITORY, **overrides):
        """Runs the hook as the worker does: bash, the default variables, nothing else.

        The hook is never started from this process: a refusal ends the hook's parent.
        """
        return subprocess.run(
            ["/bin/bash", "-c", WORKER, "worker", str(self.hook)],
            env=self.environment(event, repository, **overrides), capture_output=True, text=True, timeout=10,
        )

    def assert_admitted(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "hook-passed\nWORKER-CONTINUED\n")

    def assert_refused(self, result):
        """The worker is gone before it can act on the hook's result."""
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stdout + result.stderr)
        self.assertIn("::error::", result.stdout)
        self.assertNotIn("WORKER-CONTINUED", result.stdout)
        self.assertNotIn("hook-", result.stdout)

    def test_push_is_admitted(self):
        self.assert_admitted(self.admit({"ref": "refs/heads/trunk", "repository": {"full_name": REPOSITORY}}))

    def test_events_without_a_pull_request_are_admitted(self):
        for event in ({"schedule": "23 1 * * *"}, {"inputs": {}, "ref": "refs/heads/trunk"},
                      {"merge_group": {"head_ref": "refs/heads/gh-readonly-queue/trunk/pr-1"}},
                      {"issue": {"pull_request": {"url": "https://example.invalid/1"}}, "comment": {}},
                      {"pull_request": None, "workflow_run": None}):
            with self.subTest(event=sorted(event)):
                self.assert_admitted(self.admit(event))

    def test_pull_request_from_the_repository_is_admitted(self):
        self.assert_admitted(self.admit(pull_request({"full_name": REPOSITORY})))

    def test_repository_name_case_does_not_refuse_its_own_pull_request(self):
        self.assert_admitted(self.admit(pull_request({"full_name": "Honua-IO/Honua-Server"})))

    def test_pull_request_from_another_repository_is_refused(self):
        self.assert_refused(self.admit(pull_request({"full_name": "someone/honua-server"})))

    def test_pull_request_from_a_longer_or_shorter_name_is_refused(self):
        for name in (REPOSITORY + "-fork", "x" + REPOSITORY, "honua-io/honua", REPOSITORY + "/", ""):
            with self.subTest(name=name):
                self.assert_refused(self.admit(pull_request({"full_name": name})))

    def test_pull_request_without_a_source_repository_is_refused(self):
        for head in (None, {}, {"full_name": None}, {"full_name": 7}, {"full_name": [REPOSITORY]}):
            with self.subTest(head=head):
                self.assert_refused(self.admit(pull_request(head)))
        for event in ({"pull_request": {}}, {"pull_request": {"head": None}}, {"pull_request": {"head": REPOSITORY}},
                      {"pull_request": REPOSITORY}, {"pull_request": [REPOSITORY]}, {"pull_request": True}):
            with self.subTest(event=event):
                self.assert_refused(self.admit(event))

    def test_workflow_run_follows_the_same_rule(self):
        def workflow_run(head):
            return {"action": "completed", "workflow_run": {"head_repository": head}}

        self.assert_admitted(self.admit(workflow_run({"full_name": REPOSITORY})))
        self.assert_refused(self.admit(workflow_run({"full_name": "someone/honua-server"})))
        for head in (None, {}, {"full_name": None}):
            with self.subTest(head=head):
                self.assert_refused(self.admit(workflow_run(head)))
        self.assert_refused(self.admit({"workflow_run": "completed"}))

    def test_both_sources_must_match(self):
        event = pull_request({"full_name": REPOSITORY})
        event["workflow_run"] = {"head_repository": {"full_name": "someone/honua-server"}}
        self.assert_refused(self.admit(event))

    def test_unreadable_event_is_refused(self):
        self.assert_refused(self.admit(None))
        self.assert_refused(self.admit(None, GITHUB_EVENT_PATH=str(self.root / "absent.json")))
        self.assert_refused(self.admit(None, GITHUB_EVENT_PATH=str(self.root)))
        for text in ("", "not json", "[]", '"text"', "null", '{"pull_request": '):
            with self.subTest(text=text):
                self.assert_refused(self.admit(text))

    def test_unknown_repository_is_refused(self):
        event = pull_request({"full_name": ""})
        self.assert_refused(self.admit(event, repository=None))
        self.assert_refused(self.admit(event, repository=""))
        self.assert_refused(self.admit({"ref": "refs/heads/trunk"}, repository=None))

    def test_one_event_document_is_required(self):
        other = json.dumps(pull_request({"full_name": "someone/honua-server"}))
        own = json.dumps({"ref": "refs/heads/trunk"})
        self.assert_refused(self.admit(other + "\n" + own))
        self.assert_refused(self.admit(own + "\n" + other))
        self.assert_refused(self.admit(own + "\n" + own))

    def test_failure_of_the_json_tool_is_refused(self):
        event = {"ref": "refs/heads/trunk"}
        empty = self.root / "empty"
        empty.mkdir()
        script = self.hook.read_text()
        self.assertEqual(script.count("command -p jq"), 1)
        self.hook.write_text(script.replace("command -p jq", "jq"))
        self.assert_admitted(self.admit(event))
        self.assert_refused(self.admit(event, PATH=str(empty)))

    def test_search_path_cannot_replace_the_json_tool(self):
        fake = self.root / "fake"
        fake.mkdir()
        tool = fake / "jq"
        tool.write_text("#!/bin/bash\nexit 0\n")
        tool.chmod(0o755)
        event = pull_request({"full_name": "someone/honua-server"})
        self.assert_refused(self.admit(event, PATH=f"{fake}:/usr/bin:/bin"))

    def test_any_other_failure_also_ends_the_worker(self):
        script = self.hook.read_text()
        guard = '[[ -n "${GITHUB_REPOSITORY:-}" ]] || refuse "the repository is unknown"'
        self.assertEqual(script.count(guard), 1)
        for failure in ("false", "exit 3", "undefined_command", 'echo "${UNSET_VARIABLE}"'):
            with self.subTest(failure=failure):
                self.hook.write_text(script.replace(guard, failure))
                result = self.admit({"ref": "refs/heads/trunk"})
                self.assertEqual(result.returncode, -signal.SIGKILL, result.stdout + result.stderr)
                self.assertNotIn("WORKER-CONTINUED", result.stdout)

    def children(self, pid):
        """Waits for a process to have a child and returns the child's id."""
        listing = Path(f"/proc/{pid}/task/{pid}/children")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            listed = listing.read_text().split() if listing.exists() else []
            if listed:
                return int(listed[0])
            time.sleep(0.01)
        self.fail(f"process {pid} started no child")

    def signal_during_the_decision(self, name):
        """Signals the hook while its JSON tool runs, which is after its traps are set."""
        release = self.root / f"release-{name}"
        # Whatever happens in the test, the held tool is released and the worker ended.
        self.addCleanup(release.touch)
        worker = subprocess.Popen(
            ["/bin/bash", "-c", WORKER, "worker", str(self.hook)],
            env=self.environment(pull_request({"full_name": "someone/honua-server"}),
                                 PATH=f"{self.root / 'held'}:/usr/bin:/bin", RELEASE=str(release)),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(worker.kill)
        hook = self.children(worker.pid)
        self.children(hook)
        os.kill(hook, getattr(signal, name))
        time.sleep(0.1)
        release.touch()
        stdout, stderr = worker.communicate(timeout=20)
        return worker.returncode, stdout + stderr

    def test_signals_do_not_interrupt_the_decision(self):
        held = self.root / "held"
        held.mkdir()
        tool = held / "jq"
        tool.write_text(
            '#!/bin/bash\nwhile [[ ! -e "$RELEASE" ]]; do sleep 0.02; done\nexec ' + shutil.which("jq") + ' "$@"\n')
        tool.chmod(0o755)
        script = self.hook.read_text()
        self.hook.write_text(script.replace("command -p jq", "jq"))
        for name in ("SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"):
            with self.subTest(signal=name):
                returncode, output = self.signal_during_the_decision(name)
                self.assertEqual(returncode, -signal.SIGKILL, output)
                self.assertNotIn("WORKER-CONTINUED", output)

    def test_refusal_does_not_echo_the_event(self):
        result = self.admit(pull_request({"full_name": "someone/honua-server", "secret": "do-not-print"}))
        self.assert_refused(result)
        self.assertNotIn("do-not-print", result.stdout + result.stderr)
        self.assertNotIn("someone/", result.stdout + result.stderr)


class JobAdmissionWiringTests(unittest.TestCase):
    # A file that only root can change, in a directory that only root can change, stands in
    # for the installed hook: tests cannot create root-owned files.
    ROOT_ONLY_PROGRAM = Path("/usr/bin/true").resolve()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        (self.home / "runner").mkdir(parents=True)
        runner = self.home / "runner/run.sh"
        runner.write_text('#!/bin/bash\necho "HOOK=${ACTIONS_RUNNER_HOOK_JOB_STARTED:-}"\n')
        runner.chmod(0o755)
        state = self.root / "state/1"
        state.mkdir(parents=True)
        (state / "jitconfig").write_text("configuration")
        environment = self.root / "environment"
        environment.write_text("export ACTIONS_RUNNER_HOOK_JOB_STARTED=/tmp/redirected.sh\n")
        check = self.root / "check"
        check.write_text("#!/bin/bash\n")
        check.chmod(0o755)
        self.body = embedded("RUN")
        for production, local in (
            ("/run/honua-gate-runner-draining", str(self.root / "draining")),
            ("/run/honua-gate-runner/", str(self.root / "state") + "/"),
            ("/etc/honua-gate-runner-env", str(environment)),
            ("/usr/local/bin/honua-gate-runner-check", str(check)),
        ):
            self.assertIn(production, self.body)
            self.body = self.body.replace(production, local)
        self.assertEqual(self.body.count(HOOK), 1)

    def start(self, hook):
        wrapper = self.root / "run"
        wrapper.write_text(self.body.replace(HOOK, str(hook)))
        return subprocess.run(
            ["/bin/bash", str(wrapper), "1"],
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.home)}, capture_output=True, text=True, timeout=10,
        )

    def assert_not_started(self, hook):
        result = self.start(hook)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("HOOK=", result.stdout)

    def own_hook(self, mode=0o755):
        hook = self.root / "admit.sh"
        hook.unlink(missing_ok=True)
        hook.write_text("#!/bin/bash\n")
        hook.chmod(mode)
        return hook

    def root_only(self, path):
        function = re.search(r"(?m)^root_only\(\) \{.*\}$", self.body).group(0)
        return subprocess.run(["/bin/bash", "-c", function + '\nroot_only "$1"', "check", str(path)],
                              capture_output=True, text=True, timeout=10).returncode == 0

    def test_runner_starts_with_the_admission_hook(self):
        program = self.ROOT_ONLY_PROGRAM
        if program.stat().st_uid != 0 or program.parent.stat().st_uid != 0:
            self.skipTest("no root-owned program to stand in for the installed hook")
        result = self.start(program)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"HOOK={program}")

    def test_runner_does_not_start_without_the_hook(self):
        self.assert_not_started(self.root / "absent.sh")

    def test_runner_does_not_start_when_the_hook_is_not_a_file(self):
        self.assert_not_started(self.ROOT_ONLY_PROGRAM.parent)

    def test_runner_does_not_start_with_a_hook_it_cannot_run(self):
        self.assert_not_started("/etc/os-release")

    def test_runner_does_not_start_when_others_can_replace_the_hook(self):
        # The file is root-only, but the directory that names it is not.
        shared = self.root / "shared"
        shared.mkdir()
        shared.chmod(0o777)
        hook = shared / "admit.sh"
        hook.symlink_to(self.ROOT_ONLY_PROGRAM)
        self.assertTrue(self.root_only(hook))
        self.assert_not_started(hook)

    def test_installer_refuses_a_hook_directory_others_can_change(self):
        text = INSTALLER.read_text()
        install = text[text.index("\nADMIT\n"):text.index("<<'RUN'")]
        lines = install.splitlines()
        first = next(index for index, line in enumerate(lines) if line.startswith("[[ ") and "/usr/local/bin" in line)
        check = "\n".join(lines[first:first + 2])
        for directory, accepted in ((self.ROOT_ONLY_PROGRAM.parent, True), (Path("/tmp"), False), (self.root, os.geteuid() == 0)):
            with self.subTest(directory=str(directory)):
                result = subprocess.run(["/bin/bash", "-c", check.replace("/usr/local/bin", str(directory))],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)

    @unittest.skipIf(os.geteuid() == 0, "root owns the files this test creates")
    def test_runner_does_not_start_with_a_hook_its_account_owns(self):
        for mode in (0o755, 0o555, 0o500):
            with self.subTest(mode=oct(mode)):
                self.assert_not_started(self.own_hook(mode))

    def test_only_root_owned_paths_closed_to_group_and_others_qualify(self):
        self.assertTrue(self.root_only(self.ROOT_ONLY_PROGRAM))
        self.assertTrue(self.root_only(self.ROOT_ONLY_PROGRAM.parent))
        self.assertFalse(self.root_only("/tmp"), "root-owned but writable by others")
        self.assertFalse(self.root_only(self.root / "absent"))
        if os.geteuid() != 0:
            self.assertFalse(self.root_only(self.own_hook()))
            self.assertFalse(self.root_only(self.root))

    def test_hook_is_installed_whole_and_before_the_wrapper_that_requires_it(self):
        text = INSTALLER.read_text()
        self.assertLess(text.index("<<'ADMIT'"), text.index("<<'RUN'"))
        install = text[text.index("\nADMIT\n"):text.index("<<'RUN'")]
        self.assertIn('chmod 0755 "$admit_file"', install)
        self.assertIn(f'mv -f "$admit_file" {HOOK}', install)
        self.assertNotIn(f"> {HOOK}", text)

    def test_runner_service_runs_the_wrapper_as_the_runner_account(self):
        unit = re.search(r"honua-gate-runner@\.service <<'SERVICE'\n(.*?)\nSERVICE\n", INSTALLER.read_text(), re.S).group(1)
        self.assertRegex(unit, r"(?m)^User=gate-runner-%i$")
        self.assertRegex(unit, r"(?m)^NoNewPrivileges=yes$")
        self.assertRegex(unit, r"(?m)^ExecStart=/usr/local/bin/honua-gate-runner-run %i$")
        self.assertRegex(unit, r"(?m)^Restart=always$")


if __name__ == "__main__":
    unittest.main()
