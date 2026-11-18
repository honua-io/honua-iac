"""Run the real NuGet fallback fill and publish scripts with external tools faked."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[1]
INSTALLER = MODULE / "install-nuget-fallback.sh"
TEXT = INSTALLER.read_text()

FAKES = {
    # The clone holds no files; ls-files prints PACKAGE_INPUTS, which decides the generation.
    "git": """
if [[ "$1" == clone ]]; then [[ "${CLONE_FAILS:-0}" != 1 ]] && mkdir -p "${@: -1}"; exit; fi
[[ "$1" == ls-files ]] && printf '%s\\n' "${PACKAGE_INPUTS:-inputs-a}"
""",
    "jq": "echo 11.0.100",
    "df": "printf 'Avail\\n%sG\\n' \"${FREE_GIB:-100}\"",
    "ensure-dotnet-sdk": "mkdir -p \"$2\"",
    # Ownership and mode changes need root; record them instead.
    "chown": "echo \"chown $*\" >> \"$MODE_CALLS\"",
    "chmod": "echo \"chmod $*\" >> \"$MODE_CALLS\"",
    "pkill": "exit 1",
    # A generation is root-owned when the fake chown recorded it (it is renamed afterwards).
    "stat": """
grep -q "chown -R -P root:root .*/${3##*/}$" "$MODE_CALLS" && echo 0 || echo 1000
""",
    # Writes complete packages, one without its completion marker, and one Honua package.
    "dotnet": """
echo "restore $HOME" >> "$RESTORE_CALLS"
for index in $(seq 1 "${PACKAGE_COUNT:-150}"); do
  mkdir -p "$NUGET_PACKAGES/package.$index/1.0.0"
  touch "$NUGET_PACKAGES/package.$index/1.0.0/.nupkg.metadata"
done
mkdir -p "$NUGET_PACKAGES/partial/2.0.0" "$NUGET_PACKAGES/honua.core/1.0.0"
touch "$NUGET_PACKAGES/honua.core/1.0.0/.nupkg.metadata"
exit 1
""",
}


def heredoc(marker):
    return re.search(rf"<<'{marker}'\n(.*?)\n{marker}\n", TEXT, re.S).group(1)


class NugetFallbackTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        self.root = self.temp / "fallback"
        (self.root / "staging").mkdir(parents=True)
        self.calls = self.temp / "restore-calls"
        self.modes = self.temp / "mode-calls"
        self.calls.touch()
        self.modes.touch()
        bin_dir = self.temp / "bin"
        bin_dir.mkdir()
        for name, body in FAKES.items():
            (bin_dir / name).write_text("#!/bin/bash\n" + body)
            (bin_dir / name).chmod(0o755)
        self.path = f"{bin_dir}:/usr/bin:/bin"
        for marker in ("FILL", "PUBLISH"):
            (self.temp / f"{marker}.sh").write_text(heredoc(marker))

    def run_script(self, marker, overrides):
        env = {"PATH": self.path, "HONUA_NUGET_FALLBACK_ROOT": str(self.root),
               "HONUA_FILL_MIN_FREE_GIB": "60", "RESTORE_CALLS": str(self.calls),
               "MODE_CALLS": str(self.modes), **overrides}
        return subprocess.run(["/bin/bash", str(self.temp / f"{marker}.sh")], env=env,
                              capture_output=True, text=True, timeout=30)

    def refresh(self, **overrides):
        """The service: publish runs after the fill unit stops, with its result."""
        result = self.run_script("FILL", overrides)
        outcome = "success" if result.returncode == 0 else "exit-code"
        published = self.run_script("PUBLISH", {**overrides, "SERVICE_RESULT": outcome})
        self.assertEqual(published.returncode, 0, published.stderr)
        return result

    def stage(self, entry):
        (self.root / "staging" / "generation").write_text(entry + "\n")
        return self.run_script("PUBLISH", {})

    def current(self):
        return (self.root / "current").resolve()

    def generations(self):
        return sorted(path.name for path in self.root.glob("gen-*"))

    def restores(self):
        return self.calls.read_text().splitlines()

    def test_publishes_complete_nuget_packages_read_only(self):
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        published = self.current()
        self.assertTrue((published / "package.1/1.0.0/.nupkg.metadata").is_file())
        self.assertFalse((published / "partial").exists())
        self.assertFalse((published / "honua.core").exists())
        staged = self.root / ".incoming" / published.name
        self.assertEqual(self.modes.read_text().splitlines(),
                         [f"chown -R -P root:root {staged}", f"chmod -R a-w,a+rX {staged}"])
        self.assertEqual(list((self.root / "staging").iterdir()), [])

    def test_restore_runs_with_a_throwaway_home(self):
        self.refresh()
        home = self.restores()[0].split()[1]
        self.assertTrue(home.startswith(str(self.root / "staging" / ".work.")))
        self.assertFalse(Path(home).exists())

    def test_unchanged_package_inputs_skip_the_restore(self):
        self.refresh()
        first = self.current()
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.restores()), 1)
        self.assertEqual(self.current(), first)

    def test_keeps_the_current_and_previous_generation(self):
        self.refresh(PACKAGE_INPUTS="inputs-a")
        oldest = self.current().name
        self.refresh(PACKAGE_INPUTS="inputs-b")
        previous = self.current().name
        self.refresh(PACKAGE_INPUTS="inputs-c")
        self.assertEqual(self.generations(), sorted([previous, self.current().name]))
        self.assertNotIn(oldest, self.generations())

    def test_a_thin_restore_keeps_the_current_generation(self):
        self.refresh(PACKAGE_COUNT="400")
        first = self.current()
        for count in ("5", "300"):
            result = self.refresh(PACKAGE_INPUTS=f"inputs-{count}", PACKAGE_COUNT=count)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("keeping the current generation", result.stderr)
        self.assertEqual(self.current(), first)
        self.assertEqual(self.generations(), [first.name])

    def test_a_failed_clone_or_low_disk_publishes_nothing(self):
        self.assertNotEqual(self.refresh(CLONE_FAILS="1").returncode, 0)
        self.assertEqual(self.refresh(FREE_GIB="59").returncode, 0)
        self.assertFalse((self.root / "current").exists())
        self.assertEqual(self.restores(), [])

    def assert_nothing_published(self):
        self.assertFalse((self.root / "current").exists())
        self.assertEqual(self.modes.read_text(), "")

    def test_publish_refuses_a_staged_name_outside_the_generation_pattern(self):
        self.assertNotEqual(self.stage("../../etc").returncode, 0)
        self.assert_nothing_published()

    def test_publish_refuses_links_staged_by_the_fill_account(self):
        target = self.temp / "elsewhere"
        (target / "package.1" / "1.0.0").mkdir(parents=True)
        (self.root / "staging" / "gen-0000000000000001").symlink_to(target)
        self.assertNotEqual(self.stage("gen-0000000000000001").returncode, 0)
        inner = self.root / "staging" / "gen-0000000000000002"
        (inner / "package.1" / "1.0.0").mkdir(parents=True)
        (inner / "package.1" / "1.0.0" / "lib.dll").symlink_to(target)
        self.assertNotEqual(self.stage("gen-0000000000000002").returncode, 0)
        (self.root / "staging" / "generation").symlink_to(target / "package.1")
        self.assertEqual(self.run_script("PUBLISH", {}).returncode, 0)
        self.assert_nothing_published()
        self.assertEqual(self.generations(), [])

    def test_publish_refuses_hardlinks_and_honua_ids_staged_by_the_fill_account(self):
        for index, entry in enumerate(("honua.sdk.admin/1.0.0/.nupkg.metadata", "package.1/1.0.0/lib.dll")):
            name = f"gen-000000000000001{index}"
            path = self.root / "staging" / name / entry
            path.parent.mkdir(parents=True)
            path.touch()
            if index:
                os.link(path, self.temp / "outside.dll")
            self.assertNotEqual(self.stage(name).returncode, 0)
        self.assert_nothing_published()

    def test_publish_skips_failed_fills_and_generations_root_does_not_own(self):
        (self.root / "gen-0000000000000003").mkdir()
        self.assertEqual(self.stage("gen-0000000000000003").returncode, 0)
        (self.root / "staging" / "generation").write_text("gen-0000000000000003\n")
        self.assertEqual(self.run_script("PUBLISH", {"SERVICE_RESULT": "exit-code"}).returncode, 0)
        self.assertTrue((self.root / "staging" / "generation").exists())
        self.assert_nothing_published()


class NugetFallbackWiringTests(unittest.TestCase):
    def test_fill_account_is_confined_and_root_publishes(self):
        service = re.search(r"<<SERVICE\n(.*?)\nSERVICE\n", TEXT, re.S).group(1).splitlines()
        for line in ("User=honua-nuget-fill", "IPAddressDeny=169.254.0.0/16 fd00:ec2::254/128",
                     "ProtectSystem=strict", "ReadWritePaths=/var/lib/honua-nuget-fallback/staging",
                     "ExecStopPost=+/usr/local/sbin/honua-nuget-fallback-publish", "MemoryMax=8G",
                     "Environment=HONUA_FILL_MIN_FREE_GIB=${fill_min_free_gib}"):
            self.assertIn(line, service)
        self.assertIn("install -d -o root -g root -m 0755 \"$fallback_root\"", TEXT)

    def test_runners_receive_the_folder_and_the_host_installs_it(self):
        runner = (MODULE / "install-gate-runner.sh").read_text()
        environment = re.search(r"<<'ENVIRONMENT'\n(.*?)\nENVIRONMENT\n", runner, re.S).group(1)
        self.assertIn("export HONUA_NUGET_FALLBACK=/var/lib/honua-nuget-fallback/current", environment)
        self.assertIn('file("${path.module}/install-nuget-fallback.sh")',
                      (MODULE / "gate-runner.tf").read_text())


if __name__ == "__main__":
    unittest.main()
