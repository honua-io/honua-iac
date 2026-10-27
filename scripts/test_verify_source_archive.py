"""Tests for verify_source_archive.py and the archive attestation workflow."""
from __future__ import annotations

import gzip
import importlib.util
import io
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("verify_source_archive", HERE / "verify_source_archive.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
WORKFLOW = HERE.parent / ".github" / "workflows" / "attest-source-archive.yml"


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class VerifySourceArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.repo = Path(directory.name, "repo")
        self.repo.mkdir()
        _git(self.repo, "init", "-q")
        (self.repo / "main.tf").write_text('terraform {}\n')
        (self.repo / "bin").mkdir()
        (self.repo / "bin" / "run.sh").write_text("#!/bin/sh\n")
        (self.repo / "bin" / "run.sh").chmod(0o755)
        _git(self.repo, "add", "-A")
        _git(self.repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qm", "c")
        self.commit = _git(self.repo, "rev-parse", "HEAD")
        self.prefix = f"repo-{self.commit}"
        self.archive = Path(directory.name, "a.tar.gz")

    def write(self, raw: bytes) -> None:
        self.archive.write_bytes(gzip.compress(raw, mtime=0))

    def git_archive(self) -> bytes:
        return subprocess.run(["git", "-C", str(self.repo), "archive", "--format=tar",
                               f"--prefix={self.prefix}/", self.commit], check=True, capture_output=True).stdout

    def verify(self) -> str:
        return MODULE.verify(self.archive, repo=self.repo, commit=self.commit, prefix=self.prefix)

    def test_accepts_the_commit_tree_regardless_of_gzip_framing(self) -> None:
        self.write(self.git_archive())
        self.assertTrue(self.verify().startswith("sha256:"))

    def test_rejects_changed_content_mode_or_extra_members(self) -> None:
        def rewrite(mutate) -> bytes:
            source = tarfile.open(fileobj=io.BytesIO(self.git_archive()), mode="r:")
            out = io.BytesIO()
            target = tarfile.open(fileobj=out, mode="w:", format=tarfile.PAX_FORMAT,
                                  pax_headers=source.pax_headers)
            for member in source.getmembers():
                data = source.extractfile(member).read() if member.isfile() else None
                member, data = mutate(member, data)
                target.addfile(member, io.BytesIO(data) if data is not None else None)
            extra = mutate(None, None)
            if extra[0] is not None:
                target.addfile(extra[0], io.BytesIO(extra[1]))
            target.close()
            return out.getvalue()

        def content(member, data):
            if member is not None and member.name.endswith("main.tf"):
                data = b'terraform { backend "s3" {} }\n'
                member.size = len(data)
            return member, data

        def mode(member, data):
            if member is not None and member.name.endswith("run.sh"):
                member.mode = 0o644
            return member, data

        def extra(member, data):
            if member is None:
                info = tarfile.TarInfo(f"{self.prefix}/injected.tf")
                info.size = 1
                return info, b"x"
            return member, data

        # A faithful rewrite (different tar writer, same tree) must still pass,
        # so the refusals below are caused by the mutation alone.
        self.write(rewrite(lambda member, data: (member, data)))
        self.verify()
        for label, mutate in {"content": content, "mode": mode, "extra": extra}.items():
            with self.subTest(label):
                self.write(rewrite(mutate))
                with self.assertRaises(MODULE.ArchiveMismatch):
                    self.verify()

    def test_rejects_an_archive_of_another_commit(self) -> None:
        self.write(self.git_archive())
        with self.assertRaisesRegex(MODULE.ArchiveMismatch, "pax header"):
            MODULE.verify(self.archive, repo=self.repo, commit="0" * 40, prefix=self.prefix)


class AttestationWorkflowContractTests(unittest.TestCase):
    workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_attests_only_verified_trunk_archives(self) -> None:
        attest = self.workflow.split("\n  attest:\n", 1)[1]
        self.assertIn("if: github.event_name != 'pull_request' && github.ref == 'refs/heads/trunk'", attest)
        self.assertIn("id-token: write", attest)
        self.assertIn("attestations: write", attest)
        verify = attest.index("scripts/verify_source_archive.py")
        self.assertLess(verify, attest.index("anchore/sbom-action@"))
        self.assertLess(verify, attest.index("actions/attest-build-provenance@"))
        self.assertLess(verify, attest.index("actions/attest-sbom@"))
        self.assertIn('url="https://github.com/${GITHUB_REPOSITORY}/archive/${GITHUB_SHA}.tar.gz"', attest)
        self.assertIn("format: cyclonedx-json", attest)
        self.assertEqual(2, attest.count("subject-path: ${{ env.ARCHIVE }}"))
        contract = self.workflow.split("\n  contract:\n", 1)[1].split("\n  attest:\n", 1)[0]
        self.assertNotIn("id-token", contract)
        for action in re.findall(r"uses:\s+(\S+)", self.workflow):
            self.assertRegex(action, r"@[0-9a-f]{40}$")


if __name__ == "__main__":
    unittest.main()
