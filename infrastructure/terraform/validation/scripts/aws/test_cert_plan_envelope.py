#!/usr/bin/env python3
"""Real pinned age encryption; synthetic local keys/packets and fake GitHub API.

No live identity, network call, cloud resource, or standing plan is involved.
Set HONUA_CERT_TEST_TOOLS to a verified age/age-keygen cache before running.
"""
import hashlib
import io
import json
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

import cert_plan_envelope as envelope

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[4]
PAYLOAD = "AUTHORED_PRIVATE_PACKET_CONTENT_NEVER_PUBLIC"
WORKFLOW_SHA = "a" * 40
TOOL_ENV = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"]}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, data):
    path.write_bytes(data if isinstance(data, bytes) else json.dumps(data).encode())
    path.chmod(0o600)


class EnvelopeControls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.private = self.base / "private"
        self.private.mkdir(mode=0o700)
        self.tools = Path(os.environ["HONUA_CERT_TEST_TOOLS"])
        for name in envelope.AGE_FILES:
            envelope.tool(self.tools, name)
        self.identity = self.private / "fixture-identity"
        self.other_identity = self.private / "other-fixture-identity"
        for path in (self.identity, self.other_identity):
            subprocess.run([str(self.tools / "age-keygen"), "-o", str(path)],
                           capture_output=True, check=True, env=TOOL_ENV)
            path.chmod(0o600)
        recipient = subprocess.check_output([str(self.tools / "age-keygen"), "-y", str(self.identity)], text=True, env=TOOL_ENV).strip()
        self.repository = self.base / "source"
        self.script = self.repository / HERE.relative_to(REPOSITORY) / "cert_plan_envelope.py"
        self.script.parent.mkdir(parents=True)
        shutil.copyfile(HERE / "cert_plan_envelope.py", self.script)
        (self.repository / "release").mkdir()
        self.policy = {"schema": "honua.aws-cert-plan-recipient/v1", "status": "configured",
                       "recipient": recipient, "recipientSha256": sha(recipient.encode())}
        self.policy_file = self.repository / "release/aws-cert-plan-recipient.json"
        save(self.policy_file, self.policy)
        for args in (["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "synthetic fixture"]):
            subprocess.run(["git", *args], cwd=self.repository, capture_output=True, check=True)
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repository, text=True).strip()
        self.packet = self.private / "original-packet"
        self.packet.mkdir(mode=0o700)
        for name in envelope.PACKET_FILES - {"packet.json"}:
            save(self.packet / name, (name + "\n" + PAYLOAD).encode())
        # Preserve an actual authored binary ZIP through age and tar, while
        # semantic Terraform/payload verification remains producer-owned.
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("handler.py", "def handler(event, context): return True\n")
        save(self.packet / "bootstrap.zip", buffer.getvalue())
        save(self.packet / "module-inputs.json", {
            "schema": "honua.aws-cert-module-inputs/v1", "modulesJsonSha256": "d" * 64,
            "modules": [{"key": "honua.vpc", "source": "registry.terraform.io/terraform-aws-modules/vpc/aws",
                         "version": "5.21.0", "dir": ".terraform/modules/vpc"}],
            "files": {"modules.json": {"sha256": "d" * 64, "size": 128}}, "links": {}})
        binding = "b" * 64
        manifest = {"schema": "honua.aws-cert-plan-packet/v1", "files": {
            name: sha((self.packet / name).read_bytes()) for name in sorted(envelope.PACKET_FILES - {"packet.json"})},
            "planMetadataDigest": binding, "approvalStatus": "not-approved", "qualificationStatus": "not-evaluated"}
        save(self.packet / "packet.json", manifest)
        self.producer = {"schema": "honua.aws-cert-plan-public/v1", "status": "planned-unapproved",
                         "approvalStatus": "not-approved", "qualificationStatus": "not-evaluated",
                         "iacRevision": revision, "candidateDigest": "c" * 64,
                         "planSha256": sha((self.packet / "plan.bin").read_bytes()), "planMetadataDigest": binding,
                         "packetSha256": sha((self.packet / "packet.json").read_bytes()),
                         "expiresAtUtc": (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()}
        self.producer_file = self.private / "producer.json"
        save(self.producer_file, self.producer)
        self.exports = self.private / "exports"
        self.exports.mkdir(mode=0o700)
        self.received = self.private / "received"
        self.received.mkdir(mode=0o700)
        self.expected = {"schema": "honua.aws-cert-plan-receive/v1", "runId": 12345, "attempt": 2,
                         "workflowHeadSha": WORKFLOW_SHA, "iacRevision": revision,
                         "candidateDigest": self.producer["candidateDigest"]}
        self.expected_file = self.private / "expected.json"
        save(self.expected_file, self.expected)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("AWS_", "GH_", "GIT_", "GITHUB_", "LD_", "PYTHON"))}
        self.env.update(GITHUB_REPOSITORY=envelope.REPOSITORY, GITHUB_REF="refs/heads/trunk",
                        GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_WORKFLOW_SHA=WORKFLOW_SHA,
                        GITHUB_SHA=WORKFLOW_SHA, GITHUB_RUN_ID="12345", GITHUB_RUN_ATTEMPT="2",
                        GITHUB_WORKFLOW_REF=f"{envelope.REPOSITORY}/{envelope.WORKFLOW}@refs/heads/trunk")
        self.archive = self.private / "public-artifact.zip"
        self.api = self.private / "github-api.json"
        self.journal = self.private / "github-calls.jsonl"
        fake_bin = self.base / "bin"
        fake_bin.mkdir()
        fake = fake_bin / "gh"
        fake.write_text('''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
api=Path(''' + repr(str(self.api)) + ''')
data=json.loads(api.read_text())
with Path(''' + repr(str(self.journal)) + ''').open('a') as log:log.write(json.dumps(sys.argv[1:])+'\\n')
assert sys.argv[1:4]==['api','--hostname','github.com']
assert not any(x.startswith('AWS_') for x in os.environ)
endpoint=sys.argv[-1]
if '/attempts/' in endpoint:print(json.dumps(data['run']))
elif '/artifacts?' in endpoint:print(json.dumps({'total_count':len(data['artifacts']),'artifacts':data['artifacts']}))
elif endpoint.endswith('/zip'):sys.stdout.buffer.write(Path(''' + repr(str(self.archive)) + ''').read_bytes())
else:sys.exit(91)
''')
        fake.chmod(0o700)
        self.env["PATH"] = str(fake_bin) + ":" + self.env["PATH"]

    def invoke(self, operation, identity=None):
        arguments = ["python3", str(self.script), operation,
                     "--output-directory", str(self.exports if operation == "seal" else self.received),
                     "--tools-directory", str(self.tools)]
        if operation == "seal":
            arguments += ["--packet", str(self.packet), "--producer-receipt", str(self.producer_file)]
        else:
            save(self.expected_file, self.expected)
            arguments += ["--expected", str(self.expected_file), "--identity", str(identity or self.identity)]
        result = subprocess.run(arguments, env=self.env, capture_output=True, text=True, timeout=60, check=False)
        self.assertNotIn(PAYLOAD, result.stdout + result.stderr)
        self.assertNotIn("AGE-SECRET-KEY", result.stdout + result.stderr)
        self.assertNotIn(str(self.private), result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        return result, json.loads(result.stdout)

    def publish_fixture(self, mutate=None):
        result, receipt = self.invoke("seal")
        self.assertEqual(result.returncode, 0, result.stdout)
        export = next(self.exports.iterdir())
        if mutate:
            mutate(export)
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name in ("plan.age", "receipt.json"):
                archive.write(export / name, arcname=name)
        self.api_data = {"run": {"id": 12345, "run_attempt": 2, "head_sha": WORKFLOW_SHA,
                                 "head_branch": "trunk", "event": "workflow_dispatch", "path": envelope.WORKFLOW,
                                 "status": "completed", "conclusion": "success",
                                 "repository": {"full_name": envelope.REPOSITORY},
                                 "head_repository": {"full_name": envelope.REPOSITORY}},
                         "artifacts": [{"id": 99, "name": "standing-aws-cert-plan-12345-2", "expired": False,
                                        "size_in_bytes": self.archive.stat().st_size,
                                        "digest": "sha256:" + sha(self.archive.read_bytes()),
                                        "workflow_run": {"id": 12345, "head_sha": WORKFLOW_SHA}}]}
        save(self.api, self.api_data)
        return export, receipt

    def refused_receive(self, reason, identity=None):
        result, receipt = self.invoke("receive", identity=identity)
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertEqual(receipt["reason"], reason)
        self.assertFalse(list(self.received.glob("aws-cert-retained-*")))
        self.assertFalse(list(self.received.glob(".receive-*")))

    def test_real_age_roundtrip_and_exact_run_download(self):
        export, public = self.publish_fixture()
        self.assertEqual({p.name for p in export.iterdir()}, {"plan.age", "receipt.json"})
        self.assertNotIn(PAYLOAD.encode(), (export / "plan.age").read_bytes())
        self.assertEqual(public["status"], "encrypted-awaiting-local-retention")
        result, retained = self.invoke("receive")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(retained["status"], "retained-unapproved")
        self.assertEqual(retained["approvalStatus"], "not-approved")
        self.assertEqual(retained["qualificationStatus"], "not-evaluated")
        container = next(self.received.glob("aws-cert-retained-*"))
        self.assertEqual({p.name for p in container.iterdir()}, {"packet", "receipt.json"})
        for path in (container / "packet").iterdir():
            self.assertEqual(path.read_bytes(), (self.packet / path.name).read_bytes())
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        calls = [json.loads(l)[-1] for l in self.journal.read_text().splitlines()]
        self.assertEqual(calls, [f"repos/{envelope.REPOSITORY}/actions/runs/12345/attempts/2",
                                 f"repos/{envelope.REPOSITORY}/actions/runs/12345/artifacts?per_page=100",
                                 f"repos/{envelope.REPOSITORY}/actions/artifacts/99/zip"])

    def test_wrong_local_identity_refused_before_github(self):
        self.publish_fixture()
        self.refused_receive("recipient-key-mismatch", self.other_identity)
        self.assertFalse(self.journal.exists())

    def test_install_tools_rejects_hash_correct_nonexecutable_cache(self):
        cache = self.private / "tool-cache"
        cache.mkdir(mode=0o700)
        shutil.copyfile(self.tools / "age", cache / "age")
        (cache / "age").chmod(0o600)
        archive_data = io.BytesIO()
        with tarfile.open(fileobj=archive_data, mode="w:gz") as archive:
            for name in envelope.AGE_FILES:
                content = (self.tools / name).read_bytes()
                member = tarfile.TarInfo("age/" + name)
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
        with (mock.patch.object(envelope, "AGE_ARCHIVE_SHA", sha(archive_data.getvalue())),
              mock.patch.object(envelope.urllib.request, "urlopen", return_value=io.BytesIO(archive_data.getvalue())),
              self.assertRaisesRegex(envelope.Refused, "encryption-tool-not-executable")):
            envelope.install_tools(cache)

    def test_packet_budget_reserves_transport_overhead(self):
        total = sum(path.stat().st_size for path in self.packet.iterdir() if path.name != "packet.json")
        with (mock.patch.object(envelope, "MAX_PACKET_BYTES", total - 1),
              self.assertRaisesRegex(envelope.Refused, "packet-too-large")):
            envelope.check_packet(self.packet, self.producer)
        self.assertFalse(list(self.exports.iterdir()))

    def test_wrong_actual_workflow_source_or_attempt_is_refused(self):
        self.publish_fixture()
        self.api_data["run"]["head_sha"] = "d" * 40
        save(self.api, self.api_data)
        self.refused_receive("github-run-mismatch")

    def test_wrong_iac_or_candidate_is_refused(self):
        self.publish_fixture()
        self.expected["candidateDigest"] = "d" * 64
        self.refused_receive("candidate-or-iac-mismatch")

    def test_ciphertext_tampering_is_refused_before_decrypt(self):
        def mutate(export):
            data = bytearray((export / "plan.age").read_bytes())
            data[-1] ^= 1
            save(export / "plan.age", bytes(data))
        self.publish_fixture(mutate)
        self.refused_receive("envelope-mismatch")

    def test_authentication_failure_never_extracts_plaintext_prefix(self):
        def mutate(export):
            data = bytearray((export / "plan.age").read_bytes())
            data[-1] ^= 1
            save(export / "plan.age", bytes(data))
            receipt = json.loads((export / "receipt.json").read_text())
            receipt["ciphertextSha256"] = sha(bytes(data))
            save(export / "receipt.json", receipt)
        self.publish_fixture(mutate)
        self.refused_receive("tool-failed")

    def test_wrong_artifact_download_digest_is_refused(self):
        self.publish_fixture()
        self.api_data["artifacts"][0]["digest"] = "sha256:" + "d" * 64
        save(self.api, self.api_data)
        self.refused_receive("artifact-download-mismatch")

    def test_duplicate_or_missing_artifact_is_refused(self):
        self.publish_fixture()
        self.api_data["artifacts"].append(self.api_data["artifacts"][0])
        save(self.api, self.api_data)
        self.refused_receive("artifact-missing-or-ambiguous")

    def test_untrusted_sender_source_cannot_encrypt(self):
        self.env["GITHUB_REF"] = "refs/heads/unreviewed"
        result, receipt = self.invoke("seal")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(receipt["reason"], "trusted-workflow-required")
        self.assertFalse(list(self.exports.iterdir()))

    def test_ambient_git_settings_do_not_reach_source_commands(self):
        self.env.update(GIT_PAGER="cat", GIT_TERMINAL_PROMPT="0",
                        GIT_DIR=str(self.base / "missing-repository"),
                        GIT_WORK_TREE=str(self.private), GIT_INDEX_FILE=str(self.base / "missing-index"),
                        GIT_CONFIG_COUNT="invalid-if-inherited")
        result, receipt = self.invoke("seal")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(receipt["producer"]["iacRevision"], self.producer["iacRevision"])
        self.assertEqual(len(list(self.exports.iterdir())), 1)

    def test_uncommitted_recipient_substitution_cannot_encrypt(self):
        changed = dict(self.policy)
        changed["recipient"] = subprocess.check_output([str(self.tools / "age-keygen"), "-y", str(self.other_identity)], text=True, env=TOOL_ENV).strip()
        changed["recipientSha256"] = sha(changed["recipient"].encode())
        save(self.policy_file, changed)
        result, receipt = self.invoke("seal")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(receipt["reason"], "source-dirty")
        self.assertFalse(list(self.exports.iterdir()))

    def test_replacement_commit_cannot_substitute_recipient(self):
        changed = dict(self.policy)
        changed["recipient"] = subprocess.check_output(
            [str(self.tools / "age-keygen"), "-y", str(self.other_identity)],
            text=True, env=TOOL_ENV).strip()
        changed["recipientSha256"] = sha(changed["recipient"].encode())
        save(self.policy_file, changed)
        subprocess.run(["git", "add", str(self.policy_file)], cwd=self.repository,
                       capture_output=True, check=True)
        tree = subprocess.check_output(["git", "write-tree"], cwd=self.repository, text=True).strip()
        original = self.producer["iacRevision"]
        alternate = subprocess.check_output(
            ["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
             "commit-tree", tree, "-p", original, "-m", "synthetic replacement"],
            cwd=self.repository, text=True).strip()
        subprocess.run(["git", "replace", original, alternate], cwd=self.repository,
                       capture_output=True, check=True)
        self.assertFalse(subprocess.check_output(["git", "status", "--porcelain"],
                                                 cwd=self.repository).strip())
        result, receipt = self.invoke("seal")
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertEqual(receipt["reason"], "source-dirty")
        self.assertFalse(list(self.exports.iterdir()))

    def test_hidden_recipient_substitution_cannot_encrypt(self):
        # The alternate recipient is a real disposable age identity, not an
        # invalid string rejected by policy syntax instead of source binding.
        changed = dict(self.policy)
        changed["recipient"] = subprocess.check_output(
            [str(self.tools / "age-keygen"), "-y", str(self.other_identity)], text=True, env=TOOL_ENV).strip()
        changed["recipientSha256"] = sha(changed["recipient"].encode())
        for flag in ("skip-worktree", "assume-unchanged"):
            with self.subTest(flag=flag):
                subprocess.run(["git", "update-index", "--" + flag, str(self.policy_file)],
                               cwd=self.repository, capture_output=True, check=True)
                try:
                    save(self.policy_file, changed)
                    self.assertFalse(subprocess.check_output(
                        ["git", "status", "--porcelain"], cwd=self.repository).strip())
                    result, receipt = self.invoke("seal")
                    self.assertEqual(result.returncode, 3, result.stdout)
                    self.assertEqual(receipt["reason"], "hidden-index-flags-refused")
                    self.assertFalse(list(self.exports.iterdir()))
                finally:
                    save(self.policy_file, self.policy)
                    subprocess.run(["git", "update-index", "--no-" + flag, str(self.policy_file)],
                                   cwd=self.repository, capture_output=True, check=True)

    def test_hidden_recipient_mode_change_cannot_encrypt(self):
        subprocess.run(["git", "config", "core.filemode", "false"],
                       cwd=self.repository, capture_output=True, check=True)
        self.policy_file.chmod(0o700)
        self.assertFalse(subprocess.check_output(["git", "status", "--porcelain"], cwd=self.repository).strip())
        result, receipt = self.invoke("seal")
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertEqual(receipt["reason"], "recipient-mode-or-tracking-invalid")
        self.assertFalse(list(self.exports.iterdir()))

    def test_expired_producer_packet_is_refused(self):
        self.producer["expiresAtUtc"] = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
        save(self.producer_file, self.producer)
        result, receipt = self.invoke("seal")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(receipt["reason"], "plan-expired")

    def test_old_packet_without_retained_bootstrap_payload_is_refused(self):
        manifest = json.loads((self.packet / "packet.json").read_bytes())
        for name in ("bootstrap.zip", "bootstrap-inputs.json"):
            (self.packet / name).unlink()
            del manifest["files"][name]
        save(self.packet / "packet.json", manifest)
        self.producer["packetSha256"] = sha((self.packet / "packet.json").read_bytes())
        save(self.producer_file, self.producer)
        result, receipt = self.invoke("seal")
        self.assertEqual(result.returncode, 3, result.stdout)
        self.assertEqual(receipt["reason"], "packet-files-invalid")
        self.assertFalse(list(self.exports.iterdir()))

    def test_modified_private_packet_is_refused(self):
        save(self.packet / "plan.bin", b"replaced after original receipt")
        result, receipt = self.invoke("seal")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(receipt["reason"], "packet-file-mismatch")

    def test_traversal_or_link_archive_cannot_escape(self):
        for kind in ("traversal", "symlink", "hardlink", "duplicate"):
            with self.subTest(kind=kind):
                archive_path = self.private / (kind + ".tar")
                with tarfile.open(archive_path, "w", format=tarfile.USTAR_FORMAT) as archive:
                    for name in sorted(envelope.PACKET_FILES):
                        member = tarfile.TarInfo(name)
                        member.size = 1
                        if name == "review.txt":
                            if kind == "traversal":
                                member.name = "../escaped"
                            elif kind == "duplicate":
                                member.name = "packet.json"
                            else:
                                member.type = tarfile.SYMTYPE if kind == "symlink" else tarfile.LNKTYPE
                                member.linkname = "../escaped"
                                member.size = 0
                        archive.addfile(member, io.BytesIO(b"x") if member.size else None)
                destination = self.private / (kind + "-out")
                with self.assertRaises(envelope.Refused):
                    envelope.extract_packet(archive_path, destination)
                self.assertFalse((self.private / "escaped").exists())
                self.assertFalse(list(destination.iterdir()))

    def test_valid_encryption_with_traversal_content_is_refused_after_authentication(self):
        def mutate(export):
            malformed = self.private / "unsafe.tar"
            with tarfile.open(malformed, "w", format=tarfile.USTAR_FORMAT) as archive:
                for name in sorted(envelope.PACKET_FILES):
                    member = tarfile.TarInfo("../escaped" if name == "review.txt" else name)
                    member.size = 1
                    archive.addfile(member, io.BytesIO(b"x"))
            malformed.chmod(0o600)
            ciphertext = export / "plan.age"
            ciphertext.unlink()
            envelope.command([str(self.tools / "age"), "-r", self.policy["recipient"],
                              "-o", str(ciphertext), str(malformed)], directory=self.private)
            ciphertext.chmod(0o600)
            receipt = json.loads((export / "receipt.json").read_text())
            receipt["ciphertextSha256"] = sha(ciphertext.read_bytes())
            save(export / "receipt.json", receipt)
        self.publish_fixture(mutate)
        self.refused_receive("archive-files-invalid")
        self.assertFalse((self.received / "escaped").exists())

    def test_output_directory_cannot_be_public(self):
        self.exports.chmod(0o755)
        result, receipt = self.invoke("seal")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(receipt["reason"], "path-permissions-invalid")


if __name__ == "__main__":
    unittest.main()
