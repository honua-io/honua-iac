#!/usr/bin/env python3
"""Encrypt/receive only the standing-cert unapproved private packet format.

No Terraform, AWS credentials, approval, or deployment operation exists here.
The receiver downloads its own exact-run GitHub artifact; caller JSON is not
accepted as an authenticated workflow execution record.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path

REPOSITORY = "honua-io/honua-server"
WORKFLOW = ".github/workflows/standing-aws-cert-plan.yml"
SCHEMA = "honua.aws-cert-plan-envelope/v1"
SHA = r"[0-9a-f]{64}"
MAX_BYTES = 256 * 1024 * 1024
PACKET_FILES = {"request.json", "context-before.json", "context-after.json", "diagnostic.log",
                "plan.bin", "metadata.json", "metadata.json.digest", "review.txt", "packet.json"}
PUBLIC_FIELDS = {"schema", "status", "approvalStatus", "qualificationStatus", "iacRevision",
                 "candidateDigest", "planSha256", "planMetadataDigest", "expiresAtUtc", "packetSha256"}
AGE_URL = "https://github.com/FiloSottile/age/releases/download/v1.3.2/age-v1.3.2-linux-amd64.tar.gz"
AGE_ARCHIVE_SHA = "cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10"
AGE_FILES = {"age": "eb7dd1b518f0a307c99cd97782623c5321da049154b04acd2d98d21aa7bc9b2c",
             "age-keygen": "0a0009db842259d6717f7eeb30acb6b90d2a2eb924c6acd0a0db0ca1f1537899"}


class Refused(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Refused(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def regular(path, private=True, directory=False):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts, "path-invalid")
    for node in (path, *path.parents):
        require(not node.is_symlink(), "symlink-refused")
    for parent in path.parents:
        info = parent.stat()
        require(info.st_uid in (0, os.getuid()) and (not info.st_mode & 0o022
                or (info.st_uid == 0 and info.st_mode & stat.S_ISVTX)), "replaceable-parent-refused")
    info = path.stat()
    require(info.st_uid in (os.getuid(), 0) and (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)),
            "path-owner-or-type-invalid")
    require((not private and not info.st_mode & 0o022) or
            (private and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600)),
            "path-permissions-invalid")
    if not directory:
        require(info.st_size <= MAX_BYTES, "file-too-large")
    return path


def read_json(path, private=True):
    return json.loads(regular(path, private).read_bytes())


def save(path, value):
    data = value if isinstance(value, bytes) else json.dumps(value, sort_keys=True, indent=2).encode() + b"\n"
    with path.open("xb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def timestamp(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None, "expiry-invalid")
    return parsed


def command(args, *, directory, output=None, github=False):
    # Encryption tools receive neither cloud/GitHub credentials nor loader/plugin
    # overrides. gh alone may use the operator's existing GitHub authentication.
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "LANG": "C.UTF-8"}
    if github:
        for key in ("GH_TOKEN", "GITHUB_TOKEN"):
            if os.environ.get(key):
                env[key] = os.environ[key]
    with (directory / "command.log").open("ab") as log:
        result = subprocess.run(args, env=env, stdout=output or subprocess.PIPE,
                                stderr=log, timeout=120, check=False)
    require(result.returncode == 0, "tool-failed")
    return result.stdout or b""


def tool(directory, name):
    path = regular(Path(directory) / name, private=False)
    require(sha(path.read_bytes()) == AGE_FILES[name], "encryption-tool-mismatch")
    return str(path)


def install_tools(directory):
    directory = regular(directory, directory=True)
    data = urllib.request.urlopen(AGE_URL, timeout=60).read(MAX_BYTES + 1)
    require(len(data) <= MAX_BYTES and sha(data) == AGE_ARCHIVE_SHA, "encryption-download-mismatch")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for name, expected in AGE_FILES.items():
            member = archive.getmember("age/" + name)
            require(member.isfile() and member.size < MAX_BYTES, "encryption-archive-invalid")
            content = archive.extractfile(member).read()
            require(sha(content) == expected, "encryption-tool-mismatch")
            target = directory / name
            if target.exists():
                require(sha(regular(target, private=False).read_bytes()) == expected, "encryption-tool-mismatch")
            else:
                save(target, content)
                target.chmod(0o700)
    return {"schema": SCHEMA, "status": "tools-verified", "version": "v1.3.2",
            "archiveSha256": AGE_ARCHIVE_SHA}


def source_policy(repository, workspace):
    require(not any(k.startswith("GIT_") for k in os.environ), "git-override-refused")
    args = ["git", "-C", str(repository), "--work-tree=" + str(repository)]
    require(not command([*args, "status", "--porcelain", "--untracked-files=normal"], directory=workspace).strip(),
            "source-dirty")
    # Hidden index flags can make status report clean while tracked executable
    # or recipient bytes differ. Refuse them before reading any policy.
    entries = command([*args, "ls-files", "-v", "-z"], directory=workspace).split(b"\0")
    require(all(entry.startswith(b"H ") for entry in entries if entry), "hidden-index-flags-refused")
    revision = command([*args, "rev-parse", "HEAD"], directory=workspace).decode().strip()
    relative = "release/aws-cert-plan-recipient.json"
    path = regular(repository / relative, private=False)
    entry = command([*args, "ls-tree", "-z", revision, "--", relative], directory=workspace)
    require(re.fullmatch(rb"100644 blob [0-9a-f]{40}\t" + relative.encode() + rb"\x00", entry)
            and not path.stat().st_mode & 0o111, "recipient-mode-or-tracking-invalid")
    content = path.read_bytes()
    require(content == command([*args, "show", revision + ":" + relative], directory=workspace),
            "recipient-source-mismatch")
    policy = json.loads(content)
    require(policy["schema"] == "honua.aws-cert-plan-recipient/v1" and policy["status"] == "configured"
            and re.fullmatch(r"age1[0-9a-z]{58}", policy["recipient"])
            and sha(policy["recipient"].encode()) == policy["recipientSha256"], "recipient-unconfigured-or-invalid")
    return policy, revision


def check_public(receipt):
    require(set(receipt) == PUBLIC_FIELDS and receipt["schema"] == "honua.aws-cert-plan-public/v1"
            and receipt["status"] in ("planned-unapproved", "verified-unapproved")
            and receipt["approvalStatus"] == "not-approved" and receipt["qualificationStatus"] == "not-evaluated",
            "producer-receipt-invalid")
    require(re.fullmatch(r"[0-9a-f]{40}", receipt["iacRevision"])
            and all(re.fullmatch(SHA, receipt[k]) for k in ("candidateDigest", "planSha256", "planMetadataDigest", "packetSha256")),
            "producer-receipt-invalid")
    require(timestamp(receipt["expiresAtUtc"]) > datetime.now(timezone.utc), "plan-expired")


def check_packet(directory, receipt):
    """Check finite exact bytes; full Terraform-context semantics stay producer-owned."""
    check_public(receipt)
    directory = regular(directory, directory=True)
    require({p.name for p in directory.iterdir()} == PACKET_FILES, "packet-files-invalid")
    require(sha(regular(directory / "packet.json").read_bytes()) == receipt["packetSha256"], "packet-mismatch")
    manifest = read_json(directory / "packet.json")
    require(manifest["schema"] == "honua.aws-cert-plan-packet/v1"
            and manifest["approvalStatus"] == "not-approved" and manifest["qualificationStatus"] == "not-evaluated"
            and set(manifest["files"]) == PACKET_FILES - {"packet.json"}
            and manifest["planMetadataDigest"] == receipt["planMetadataDigest"], "packet-manifest-invalid")
    total = 0
    for name, expected in manifest["files"].items():
        path = regular(directory / name)
        total += path.stat().st_size
        require(re.fullmatch(SHA, expected) and sha(path.read_bytes()) == expected, "packet-file-mismatch")
    require(total <= MAX_BYTES and sha((directory / "plan.bin").read_bytes()) == receipt["planSha256"], "packet-mismatch")


def workflow_context():
    env = os.environ
    require(env.get("GITHUB_REPOSITORY") == REPOSITORY and env.get("GITHUB_REF") == "refs/heads/trunk"
            and env.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and env.get("GITHUB_WORKFLOW_REF") == f"{REPOSITORY}/{WORKFLOW}@refs/heads/trunk"
            and re.fullmatch(r"[0-9a-f]{40}", env.get("GITHUB_SHA", ""))
            and env.get("GITHUB_WORKFLOW_SHA") == env["GITHUB_SHA"], "trusted-workflow-required")
    require(re.fullmatch(r"[1-9][0-9]*", env.get("GITHUB_RUN_ID", ""))
            and re.fullmatch(r"[1-9][0-9]*", env.get("GITHUB_RUN_ATTEMPT", "")), "run-identity-invalid")
    return {"repository": REPOSITORY, "workflow": WORKFLOW, "ref": "refs/heads/trunk",
            "headSha": env["GITHUB_SHA"], "runId": int(env["GITHUB_RUN_ID"]),
            "attempt": int(env["GITHUB_RUN_ATTEMPT"])}


def seal(packet, producer_receipt, output_parent, tools, repository):
    output_parent = regular(output_parent, directory=True)
    context = workflow_context()
    with tempfile.TemporaryDirectory(prefix=".seal-", dir=output_parent) as temporary:
        workspace = Path(temporary)
        policy, revision = source_policy(repository, workspace)
        receipt = read_json(producer_receipt)
        check_packet(packet, receipt)
        require(receipt["iacRevision"] == revision, "iac-source-mismatch")
        archive_path = workspace / "packet.tar"
        with tarfile.open(archive_path, "x", format=tarfile.USTAR_FORMAT) as archive:
            for name in sorted(PACKET_FILES):
                archive.add(Path(packet) / name, arcname=name, recursive=False)
        export = output_parent / ("encrypted-plan-" + uuid.uuid4().hex)
        export.mkdir(mode=0o700)
        try:
            ciphertext = export / "plan.age"
            command([tool(tools, "age"), "--encrypt", "-r", policy["recipient"], "-o", str(ciphertext), str(archive_path)], directory=workspace)
            # Catch changed source files during archive creation too.
            check_packet(packet, receipt)
            require(regular(ciphertext).stat().st_size <= MAX_BYTES + 1024 * 1024, "ciphertext-too-large")
            public = {"schema": SCHEMA, "status": "encrypted-awaiting-local-retention", "context": context,
                      "producer": receipt, "recipientSha256": policy["recipientSha256"],
                      "ciphertextSha256": sha(ciphertext.read_bytes()), "encryptionVersion": "age/v1.3.2",
                      "approvalStatus": "not-approved", "qualificationStatus": "not-evaluated"}
            save(export / "receipt.json", public)
            return public
        except BaseException:
            shutil.rmtree(export)
            raise


def extract_packet(archive_path, destination):
    destination.mkdir(mode=0o700)
    with tarfile.open(archive_path, "r:") as archive:
        members = []
        for member in archive:
            require(len(members) < len(PACKET_FILES), "archive-files-invalid")
            members.append(member)
        require(len(members) == len(PACKET_FILES) and {m.name for m in members} == PACKET_FILES,
                "archive-files-invalid")
        require(all(m.type in (tarfile.REGTYPE, tarfile.AREGTYPE) and not m.issparse() and not m.pax_headers
                    and m.size >= 0 for m in members)
                and sum(m.size for m in members) <= MAX_BYTES, "archive-type-or-size-invalid")
        for member in members:
            save(destination / member.name, archive.extractfile(member).read())


def github(args, workspace, output=None):
    executable = shutil.which("gh")
    require(executable is not None, "github-cli-required")
    return command([executable, "api", "--hostname", "github.com", *args],
                   directory=workspace, output=output, github=True)


def receive(expected_file, identity, output_parent, tools, repository):
    expected = read_json(expected_file)
    require(expected["schema"] == "honua.aws-cert-plan-receive/v1"
            and type(expected["runId"]) is int and expected["runId"] > 0
            and type(expected["attempt"]) is int and expected["attempt"] > 0
            and re.fullmatch(r"[0-9a-f]{40}", expected["workflowHeadSha"])
            and re.fullmatch(r"[0-9a-f]{40}", expected["iacRevision"])
            and re.fullmatch(SHA, expected["candidateDigest"]), "expected-context-invalid")
    identity = regular(identity)
    output_parent = regular(output_parent, directory=True)
    with tempfile.TemporaryDirectory(prefix=".receive-", dir=output_parent) as temporary:
        workspace = Path(temporary)
        policy, _ = source_policy(repository, workspace)
        recipient = command([tool(tools, "age-keygen"), "-y", str(identity)], directory=workspace).decode().strip()
        require(recipient == policy["recipient"], "recipient-key-mismatch")
        run_id, attempt = expected["runId"], expected["attempt"]
        run = json.loads(github([f"repos/{REPOSITORY}/actions/runs/{run_id}/attempts/{attempt}"], workspace))
        require(run["id"] == run_id and run["run_attempt"] == attempt and run["head_sha"] == expected["workflowHeadSha"]
                and run["head_branch"] == "trunk" and run["event"] == "workflow_dispatch"
                and run["path"] == WORKFLOW and run["status"] == "completed" and run["conclusion"] == "success"
                and run["repository"]["full_name"] == REPOSITORY
                and run["head_repository"]["full_name"] == REPOSITORY, "github-run-mismatch")
        artifacts = json.loads(github([f"repos/{REPOSITORY}/actions/runs/{run_id}/artifacts?per_page=100"], workspace))
        require(artifacts["total_count"] <= 100, "artifact-list-too-large")
        matches = [a for a in artifacts["artifacts"] if a["name"] == f"standing-aws-cert-plan-{run_id}-{attempt}"]
        require(len(matches) == 1, "artifact-missing-or-ambiguous")
        artifact = matches[0]
        require(not artifact["expired"] and artifact["size_in_bytes"] <= MAX_BYTES
                and artifact["workflow_run"]["id"] == run_id
                and artifact["workflow_run"]["head_sha"] == expected["workflowHeadSha"]
                and re.fullmatch("sha256:" + SHA, artifact["digest"]), "artifact-identity-invalid")
        downloaded = workspace / "download.zip"
        with downloaded.open("xb") as output:
            github([f"repos/{REPOSITORY}/actions/artifacts/{artifact['id']}/zip"], workspace, output=output)
        require(downloaded.stat().st_size <= MAX_BYTES
                and "sha256:" + sha(downloaded.read_bytes()) == artifact["digest"], "artifact-download-mismatch")
        with zipfile.ZipFile(downloaded) as archive:
            members = archive.infolist()
            require(len(members) == 2 and {m.filename for m in members} == {"plan.age", "receipt.json"}
                    and all(not m.is_dir() and stat.S_IFMT(m.external_attr >> 16) in (0, stat.S_IFREG) for m in members)
                    and sum(m.file_size for m in members) <= MAX_BYTES, "public-artifact-files-invalid")
            for member in members:
                save(workspace / member.filename, archive.read(member))
        receipt = read_json(workspace / "receipt.json")
        context = {"repository": REPOSITORY, "workflow": WORKFLOW, "ref": "refs/heads/trunk",
                   "headSha": expected["workflowHeadSha"], "runId": run_id, "attempt": attempt}
        require(receipt["schema"] == SCHEMA and receipt["context"] == context
                and receipt["status"] == "encrypted-awaiting-local-retention"
                and receipt["recipientSha256"] == policy["recipientSha256"]
                and receipt["encryptionVersion"] == "age/v1.3.2"
                and receipt["approvalStatus"] == "not-approved" and receipt["qualificationStatus"] == "not-evaluated"
                and sha((workspace / "plan.age").read_bytes()) == receipt["ciphertextSha256"], "envelope-mismatch")
        producer = receipt["producer"]
        check_public(producer)
        require(producer["iacRevision"] == expected["iacRevision"]
                and producer["candidateDigest"] == expected["candidateDigest"], "candidate-or-iac-mismatch")
        plain = workspace / "packet.tar"
        # age may write unauthenticated prefixes before final authentication.
        # Only private temp bytes exist until its complete exit status is0.
        command([tool(tools, "age"), "--decrypt", "-i", str(identity), "-o", str(plain), str(workspace / "plan.age")], directory=workspace)
        require(regular(plain).stat().st_size <= MAX_BYTES, "plaintext-too-large")
        packet = workspace / "packet"
        extract_packet(plain, packet)
        check_packet(packet, producer)
        destination = output_parent / f"aws-cert-retained-{run_id}-{attempt}-{producer['packetSha256'][:12]}"
        result = {"schema": SCHEMA, "status": "retained-unapproved", "context": context,
                  "packetSha256": producer["packetSha256"], "ciphertextSha256": receipt["ciphertextSha256"],
                  "recipientSha256": policy["recipientSha256"], "approvalStatus": "not-approved",
                  "qualificationStatus": "not-evaluated"}
        container = workspace / "retained"
        container.mkdir(mode=0o700)
        os.rename(packet, container / "packet")
        save(container / "receipt.json", result)
        for directory in (container / "packet", container):
            descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        require(not destination.exists(), "retained-packet-already-exists")
        os.rename(container, destination)
        descriptor = os.open(output_parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        return result


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    install = sub.add_parser("install-tools")
    install.add_argument("--directory", required=True, type=Path)
    sender = sub.add_parser("seal")
    sender.add_argument("--packet", required=True, type=Path)
    sender.add_argument("--producer-receipt", required=True, type=Path)
    receiver = sub.add_parser("receive")
    receiver.add_argument("--expected", required=True, type=Path)
    receiver.add_argument("--identity", required=True, type=Path)
    for command_parser in (sender, receiver):
        command_parser.add_argument("--output-directory", required=True, type=Path)
        command_parser.add_argument("--tools-directory", required=True, type=Path)
    args = parser.parse_args()
    try:
        repository = Path(__file__).resolve().parents[5]
        if args.operation == "install-tools":
            result = install_tools(args.directory)
        elif args.operation == "seal":
            result = seal(args.packet, args.producer_receipt, args.output_directory, args.tools_directory, repository)
        else:
            result = receive(args.expected, args.identity, args.output_directory, args.tools_directory, repository)
        code = 0
    except (Refused, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired, tarfile.TarError, zipfile.BadZipFile) as error:
        result = {"schema": SCHEMA, "status": "refused", "reason": str(error) if isinstance(error, Refused) else "invalid-or-unavailable-context",
                  "approvalStatus": "not-approved", "qualificationStatus": "not-evaluated"}
        code = 3
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
