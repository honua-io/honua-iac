#!/usr/bin/env python3
"""Plan the existing aws-cert root into a private, explicitly unapproved packet.

This is an operator entrypoint, not a deployment or approval actuator. All child
output is private. Only the deliberately constructed public receipt reaches stdout.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import uuid
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath

ROOT_REL = "infrastructure/terraform/examples/aws-cert"
SUBJECT = "repo:honua-io/honua-server:environment:cert"
ISSUER = "https://token.actions.githubusercontent.com"
AUDIENCE = "sts.amazonaws.com"
SHA = r"[0-9a-f]{64}"
IMAGE_KEYS = ("honua_image", "gp_batch_image", "customcode_batch_image",
              "customcode_dotnet_batch_image", "ecs_alb_image")
PACKET_FILES = {"request.json", "context-before.json", "context-after.json", "diagnostic.log",
                "plan.bin", "metadata.json", "metadata.json.digest", "review.txt",
                "bootstrap.zip", "bootstrap-inputs.json", "module-inputs.json"}
MAX_ARTIFACT_BYTES = 64 * 1024 * 1024
MAX_MODULE_BYTES = 256 * 1024 * 1024
MAX_PROVIDER_BYTES = 1536 * 1024 * 1024
BOOTSTRAP_BUILD = "terraform_data.postgis_bootstrap_build"
BOOTSTRAP_ARCHIVE = "data.archive_file.postgis_bootstrap"
BOOTSTRAP_FUNCTION = "aws_lambda_function.postgis_bootstrap"


class Refused(Exception):
    pass


def require(condition, code):
    if not condition:
        raise Refused(code)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def load(path):
    return json.loads(path.read_bytes())


def protected(path, directory=False):
    """Reject symlink traversal and group/other access, including private parent."""
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts, "private-path-invalid")
    for node in (path, *path.parents):
        require(not node.is_symlink(), "private-path-symlink")
    for parent in path.parents:
        info = parent.stat()
        require(info.st_uid in (0, os.getuid()), "private-path-parent-owner")
        # Root-owned sticky /tmp is safe for an owned private child; other
        # writable ancestors can replace paths regardless of a file's 0600 mode.
        require(not info.st_mode & 0o022 or (info.st_uid == 0 and info.st_mode & stat.S_ISVTX),
                "private-path-parent-permissions")
    info = path.stat()
    require(info.st_uid == os.getuid(), "private-path-owner")
    require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode),
            "private-path-type")
    require(stat.S_IMODE(info.st_mode) == (0o700 if directory else 0o600),
            "private-path-permissions")
    return path


def timestamp(value):
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(result.tzinfo is not None, "expiry-invalid")
    return result


def text(value):
    return isinstance(value, str) and bool(value.strip()) and len(value) <= 512


def role_arn(value, account):
    require(isinstance(value, str) and re.fullmatch(
        rf"arn:aws:iam::{account}:role/[A-Za-z0-9+=,.@_/-]+", value), "role-contract-invalid")
    return value.rsplit("/", 1)[-1]


def assumed(identity, role, account):
    name = role_arn(role, account)
    require(identity.get("Account") == account and re.fullmatch(
        rf"arn:aws:sts::{account}:assumed-role/{re.escape(name)}/[^/]+",
        identity.get("Arn", "")), "deployment-session-mismatch")


def write(path, value):
    data = value if isinstance(value, bytes) else json.dumps(value, indent=2).encode() + b"\n"
    with path.open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


class Commands:
    def __init__(self, repository, packet, environment):
        self.repository, self.packet, self.environment = repository, packet, environment

    def run(self, args, *, environment=None, output=None, seconds=120):
        with (self.packet / "diagnostic.log").open("ab") as log:
            process = subprocess.Popen(args, cwd=self.repository,
                                       env=environment or self.environment,
                                       stdout=subprocess.PIPE if output is None else output,
                                       stderr=log, start_new_session=True)
            try:
                data, _ = process.communicate(timeout=seconds)
            except BaseException:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise
            if data:
                log.write(data)
            require(process.returncode == 0, "subprocess-failed")
            return data or b""

    def json(self, args, **kwargs):
        return json.loads(self.run(args, **kwargs))

    def facts(self, root):
        # Delegate canonical backend/source/state/input semantics to the maintained
        # exact-plan substrate. No separate Terraform interpretation here.
        script = r'''source scripts/lib/tf-exec-contract.sh
backend="$(backend_identity_doc "$1" "$(tf -chdir="$1" workspace show)")"
assert_remote_backend "$backend"
assert_lock_primitive_supported "$backend" "$(terraform_version)"
identity="$(sts_identity_doc)"
assert_short_lived_identity "$identity"
assert_backend_role_separated "$backend" "$identity"
source_doc="$(iac_source_doc "$PWD" "$1" false)"
state="$(state_lineage_doc "$1")"
inputs="$(input_digest_doc "$1" "$2")"
printf '%s\n' "$backend" "$identity" "$source_doc" "$state" "$inputs"
'''
        raw = self.run(["bash", "-c", script, "standing-cert-facts", str(root),
                        self.environment["HONUA_CERT_VAR_FILE"]])
        lines = raw.splitlines()
        require(len(lines) == 5, "context-invalid")
        return dict(zip(("backend", "identity", "source", "state", "inputs"),
                        (json.loads(line) for line in lines)))


def environment(request, root):
    env = dict(os.environ)
    forbidden = ("TF_CLI_ARGS", "TF_VAR_", "TF_LOG", "GIT_", "HONUA_IAC_", "BASH_ENV", "ENV",
                 "LD_PRELOAD", "LD_LIBRARY_PATH", "PYTHONPATH", "PYTHONHOME", "AWS_ENDPOINT_URL",
                 "AWS_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "SSL_CERT_FILE", "CURL_CA_BUNDLE")
    require(not any(k.startswith(forbidden) for k in env), "environment-override-refused")
    require(not any(k.upper() in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY") for k in env),
            "environment-override-refused")
    require(not any(k in env for k in ("TF_DATA_DIR", "TF_WORKSPACE", "TF_CLI_CONFIG_FILE",
                                       "TERRAFORM_CONFIG", "TF_REATTACH_PROVIDERS",
                                       "TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE",
                                       "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_PROFILE", "AWS_DEFAULT_PROFILE",
                                       "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_ROLE_ARN")),
            "environment-override-refused")
    require(env.get("RUNNER_ENVIRONMENT") != "github-hosted", "durable-private-runtime-required")
    require(all(env.get(k) for k in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
                                    "AWS_SESSION_TOKEN")), "deployment-sts-session-required")
    # Pin region and session evidence; credential material never enters request/packet.
    env.update(AWS_REGION=request["region"], AWS_DEFAULT_REGION=request["region"],
               AWS_PAGER="", AWS_CONFIG_FILE=os.devnull, AWS_SHARED_CREDENTIALS_FILE=os.devnull,
               AWS_EC2_METADATA_DISABLED="true", TF_IN_AUTOMATION="true", CHECKPOINT_DISABLE="1",
               HONUA_IAC_SESSION_EXPIRY=request["sessionExpiresAtUtc"],
               HONUA_IAC_IDENTITY_ISSUER=ISSUER,
               HONUA_CERT_VAR_FILE=str(request["varFile"]),
               GIT_WORK_TREE=str(root.parents[3]), GIT_NO_REPLACE_OBJECTS="1",
               GIT_CONFIG_COUNT="2", GIT_CONFIG_KEY_0="core.fsmonitor", GIT_CONFIG_VALUE_0="false",
               GIT_CONFIG_KEY_1="core.untrackedCache", GIT_CONFIG_VALUE_1="false")
    # The backend obtains its own web-identity session using the protected file
    # referenced by its existing initialized descriptor, not the deployment keys.
    return env


def contracts(request):
    work = request["workloadIdentityContract"]
    execute = request["executionIdentityContract"]
    for key, value in (("workloadIdentityContractDigest", work),
                       ("executionIdentityContractDigest", execute)):
        require(request[key] == digest(canonical(value)), "identity-contract-digest-mismatch")
    account = request["accountId"]
    require(re.fullmatch(r"[0-9]{12}", account) and re.fullmatch(r"[a-z]{2}-[a-z]+-[0-9]", request["region"]),
            "target-invalid")
    require(work["schema_version"] == "v1" and work["kind"] == "aws-sts-web-identity"
            and work["credentials"] == "short-lived-sts-only"
            and work["permissions_purpose"] == "terraform-state-and-lock-only"
            and work["issuer"] == ISSUER and work["subject"] == SUBJECT
            and work["audience"] == AUDIENCE and 900 <= work["max_session_duration"] <= 3600,
            "workload-contract-invalid")
    require(execute["schema_version"] == "v1" and execute["kind"] == "honua.iac.execution-identity"
            and execute["account"] == {"account_id": account, "partition": "aws", "region": request["region"]},
            "execution-contract-invalid")
    federation = execute["federation"]
    require(federation["mode"] == "oidc" and federation["issuer"] == ISSUER
            and federation["audience"] == AUDIENCE and federation["subjects"] == [SUBJECT]
            and federation["trusted_principals"] == []
            and federation["credential_kind"] == "short-lived-sts-only"
            and 900 <= federation["max_session_duration"] <= 3600, "execution-contract-invalid")
    require(execute["separation"] == {
        "backend_access_denied_to_deployment": True, "long_lived_credentials_denied": True,
        "deployment_role_not_passable": True, "iam_user_created": False,
        "access_key_created": False}, "execution-contract-invalid")
    backend = execute["roles"]["backend_access"]["role_arn"]
    deploy = execute["roles"]["infra_deployment"]["role_arn"]
    require(backend == work["role_arn"] and backend != deploy, "role-contract-invalid")
    require(role_arn(backend, account) == work["role_name"], "role-contract-invalid")
    role_arn(deploy, account)
    require(work["backend"]["state_bucket_arn"] == "arn:aws:s3:::" + request["backend"]["bucket_id"]
            and work["backend"]["lock_table_arn"] == "", "backend-contract-invalid")
    return backend, deploy


def trust(commands, role, account):
    current = commands.json(["aws", "iam", "get-role", "--role-name", role_arn(role, account),
                             "--output", "json"])["Role"]
    require(current["Arn"] == role and current["MaxSessionDuration"] <= 3600, "live-role-mismatch")
    statements = current["AssumeRolePolicyDocument"]["Statement"]
    require(len(statements) == 1, "live-role-trust-mismatch")
    statement = statements[0]
    # Existing deployment trust uses StringLike for an exact subject; permit
    # that spelling only with the same literal, never wildcard/prefix subjects.
    condition = statement["Condition"]
    equals = condition.get("StringEquals", {})
    like = condition.get("StringLike", {})
    subject_key = "token.actions.githubusercontent.com:sub"
    audience_key = "token.actions.githubusercontent.com:aud"
    exact = lambda value, expected: value == expected or value == [expected]
    require(set(condition) <= {"StringEquals", "StringLike"}
            and set(equals) <= {subject_key, audience_key}
            and set(like) <= {subject_key} and subject_key not in (set(equals) & set(like))
            and exact(equals.get(audience_key), AUDIENCE)
            and exact(equals.get(subject_key, like.get(subject_key)), SUBJECT), "live-role-trust-mismatch")
    require(statement["Effect"] == "Allow"
            and statement["Action"] in ("sts:AssumeRoleWithWebIdentity", ["sts:AssumeRoleWithWebIdentity"])
            and statement["Principal"] == {"Federated": f"arn:aws:iam::{account}:oidc-provider/token.actions.githubusercontent.com"}
            and set(statement) <= {"Sid", "Effect", "Action", "Principal", "Condition"}, "live-role-trust-mismatch")


def validate_facts(facts, request, deploy):
    b = facts["backend"]
    expected = request["backend"]
    require(b["workspace"] == expected["workspace"] and b["location"]["object_key"] == expected["object_key"]
            and b["location"]["bucket_id"] == expected["bucket_id"]
            and b["location"]["region"] == request["region"]
            and digest(canonical(b)) == expected["configDigest"], "backend-mismatch")
    require(b["backend_access_role_arn"] == request["workloadIdentityContract"]["role_arn"], "backend-role-mismatch")
    require(facts["state"] == request["stateBefore"] and text(facts["state"]["lineage"])
            and type(facts["state"]["serial"]) is int and facts["state"]["serial"] >= 0, "state-mismatch")
    require(facts["source"]["iac_revision"] == request["iacRevision"] and facts["source"]["terraform_root"] == ROOT_REL,
            "source-mismatch")
    i = facts["identity"]
    assumed({"Account": i["account_id"], "Arn": i["arn"]}, deploy, request["accountId"])
    require(i["credential_kind"] == "sts-assumed-role" and i["evidence_mode"] == "live", "identity-invalid")


def verify_packet(path, expected_sha):
    """Verify private bytes against the retained producer receipt, never approve."""
    path = protected(path, directory=True)
    require(isinstance(expected_sha, str) and re.fullmatch(SHA, expected_sha), "packet-hash-required")
    descriptor = protected(path / "packet.json")
    require(digest(descriptor.read_bytes()) == expected_sha, "packet-hash-mismatch")
    packet = load(descriptor)
    require(packet["schema"] == "honua.aws-cert-plan-packet/v1"
            and packet["approvalStatus"] == "not-approved"
            and packet["qualificationStatus"] == "not-evaluated"
            and set(packet["files"]) == PACKET_FILES
            and {p.name for p in path.iterdir()} == PACKET_FILES | {"packet.json"}, "packet-files-invalid")
    for name, expected in packet["files"].items():
        require(re.fullmatch(SHA, expected) and digest(protected(path / name).read_bytes()) == expected,
                "packet-file-mismatch")
    metadata = load(path / "metadata.json")
    document = dict(metadata)
    binding = document.pop("plan_metadata_digest")
    require(binding == packet["planMetadataDigest"] == digest(canonical(document))
            and (path / "metadata.json.digest").read_text().strip() == binding
            and metadata["plan"]["sha256"] == digest((path / "plan.bin").read_bytes()), "plan-binding-invalid")
    artifact = load(path / "bootstrap-inputs.json")
    content = (path / "bootstrap.zip").read_bytes()
    require(artifact["schema"] == "honua.aws-cert-bootstrap-artifact/v1"
            and artifact["archiveSha256"] == digest(content)
            and artifact["buildActions"] == ["no-op"]
            and artifact["sourceCodeHash"] == base64.b64encode(hashlib.sha256(content).digest()).decode()
            and artifact["files"] == bootstrap_zip_inventory(content), "bootstrap-packet-invalid")
    modules = load(path / "module-inputs.json")
    require(modules["schema"] == "honua.aws-cert-module-inputs/v2"
            and re.fullmatch(SHA, modules["modulesJsonSha256"])
            and modules["files"]["modules.json"]["sha256"] == modules["modulesJsonSha256"]
            and bool(modules["modules"]) and bool(modules["providers"]), "module-packet-invalid")
    expiry = timestamp(metadata["expires_at_utc"])
    require(expiry > datetime.now(timezone.utc), "plan-expired")
    request = load(path / "request.json")
    require(re.fullmatch(r"[0-9a-f]{40}", request["iacRevision"])
            and re.fullmatch(SHA, request["candidateDigest"]), "source-pin-invalid")
    return {"schema": "honua.aws-cert-plan-public/v1", "status": "verified-unapproved",
            "approvalStatus": "not-approved", "qualificationStatus": "not-evaluated",
            "iacRevision": request["iacRevision"], "candidateDigest": request["candidateDigest"],
            "planSha256": metadata["plan"]["sha256"], "planMetadataDigest": binding,
            "expiresAtUtc": expiry.isoformat(), "packetSha256": expected_sha}


def validate_expiry(metadata, request, claims, started):
    created = timestamp(metadata["created_at_utc"])
    expiry = timestamp(metadata["expires_at_utc"])
    current = datetime.now(timezone.utc)
    require(started - timedelta(seconds=1) <= created <= current + timedelta(seconds=5)
            and expiry - created == timedelta(seconds=request["expiresInSeconds"])
            and expiry > current, "plan-expiry-invalid")
    require(expiry < timestamp(request["sessionExpiresAtUtc"])
            and expiry.timestamp() < claims["exp"], "session-expiring")
    require(expiry < timestamp(request["privateRetention"]["retainUntilUtc"]), "private-retention-required")


def planning_seconds(request, claims):
    deadline = min(timestamp(request["sessionExpiresAtUtc"]).timestamp(), claims["exp"])
    available = int(deadline - datetime.now(timezone.utc).timestamp() - request["expiresInSeconds"] - 5)
    require(available > 0, "session-expiring")
    return min(request["planTimeoutSeconds"], available)


def backend_only_source(config, optional=()):
    """Finite backend-only HCL; comments/whitespace may vary, executable HCL may not."""
    lines = ['terraform { backend "s3" {']
    for key in ("bucket", "key", "region", "encrypt", "use_lockfile", "kms_key_id", "workspace_key_prefix"):
        if config.get(key) is not None and (key not in ("kms_key_id", "workspace_key_prefix") or key in optional):
            lines.append(f"{key} = {json.dumps(config[key])}")
    lines.append("assume_role_with_web_identity = {")
    web = config["assume_role_with_web_identity"]
    require({k for k, v in web.items() if v is not None} <= {"role_arn", "web_identity_token_file"},
            "backend-source-unsupported")
    for key in ("role_arn", "web_identity_token_file"):
        lines.append(f"{key} = {json.dumps(web[key])}")
    return "\n".join([*lines, "} } }"])


def validate_backend_transport(config):
    """An initialized backend must not route its web identity to alternate services."""
    require(isinstance(config, dict), "backend-config-invalid")
    unsafe = ("endpoint", "proxy", "ca_bundle", "cert_file", "shared_config_files",
              "shared_credentials_files", "insecure", "skip_credentials_validation",
              "s3_use_path_style")
    require(not any(any(part in key for part in unsafe) and value not in (None, "", False, [], {})
                    for key, value in config.items()), "backend-transport-override-refused")


def validate_backend_descriptor_path(path):
    """Other local users must not be able to replace or rewrite backend routing."""
    for node in (path, *path.parents):
        info = node.lstat()
        require(info.st_uid in (0, os.getuid()) and not stat.S_ISLNK(info.st_mode)
                and (not info.st_mode & 0o022 or (info.st_uid == 0 and info.st_mode & stat.S_ISVTX)),
                "backend-path-permissions")
        require(stat.S_ISREG(info.st_mode) if node == path else stat.S_ISDIR(info.st_mode),
                "backend-path-permissions")


def hcl_tokens(value):
    tokens = re.findall(r'"(?:[^"\\]|\\.)*"|/\*.*?\*/|//[^\n]*|\#[^\n]*|\s+|[A-Za-z_][A-Za-z0-9_-]*|.', value, re.DOTALL)
    return [token for token in tokens if not token.isspace() and not token.startswith(("#", "//", "/*"))]


def validate_runtime_source(commands, root, repository, config):
    flags = commands.run(["git", "ls-files", "-v", "-z"])
    # Reject hidden-index state for the whole checkout before sourcing any
    # executable helper. This also covers tracked templates/build assets used by
    # local modules, not just .tf files. Lowercase tags mean assume-unchanged;
    # S means skip-worktree. A normal cached entry is H.
    require(all(entry[:2] == b"H " for entry in flags.split(b"\0") if entry), "hidden-index-flags-refused")
    backend = root / "backend.tf"
    tokens = hcl_tokens(backend.read_text()) if backend.is_file() and not backend.is_symlink() else []
    require(backend.is_file() and not backend.is_symlink()
            and tokens == hcl_tokens(backend_only_source(config, tokens)), "backend-source-invalid")
    entries = commands.run(["git", "ls-tree", "-r", "-z", "HEAD"])
    tracked = {}
    for entry in entries.split(b"\0"):
        if entry:
            descriptor, name = entry.split(b"\t", 1)
            tracked[name.decode()] = descriptor.split()[2].decode()
    # Git status can trust a configured fsmonitor and report a modified helper
    # clean. Compare each maintained executable helper directly to HEAD before
    # any of them is sourced or executed.
    for relative in ("scripts/lib/tf-exec-contract.sh", "scripts/terraform-exact-plan.sh",
                     "scripts/terraform-backend-identity.sh"):
        helper = repository / relative
        require(helper.is_file() and not helper.is_symlink() and relative in tracked,
                "helper-source-invalid")
        data = helper.read_bytes()
        object_id = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data,
                                 usedforsecurity=False).hexdigest()
        require(object_id == tracked[relative], "helper-source-modified")
    # Cover the fixed root and all maintained local module/component sources;
    # other operator example backends are outside this runtime's source set.
    directories = (root, repository / "infrastructure/terraform/modules",
                   repository / "infrastructure/terraform/components")
    seen = set()
    for directory in directories:
        if not directory.exists():
            continue
        for parent, children, files in os.walk(directory):
            children[:] = [name for name in children if name not in (".terraform", ".git")
                           and Path(parent) / name != root / "postgis-bootstrap/build"]
            require(not any((Path(parent) / name).is_symlink() for name in children), "source-symlink-refused")
            for name in files:
                path = Path(parent) / name
                if path == backend or path == root / "postgis-bootstrap/bootstrap.zip":
                    continue
                require(not path.is_symlink(), "source-symlink-refused")
                relative = str(path.relative_to(repository))
                seen.add(relative)
                require(relative in tracked, "ignored-terraform-source-refused")
                data = path.read_bytes()
                # Git object identity, not a new cryptographic signing scheme.
                object_id = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data,
                                         usedforsecurity=False).hexdigest()
                require(object_id == tracked[relative], "terraform-source-modified")
    prefixes = tuple(str(directory.relative_to(repository)) + "/" for directory in directories)
    expected = {name for name in tracked if name.startswith(prefixes)}
    require(expected <= seen, "terraform-source-missing")


def artifact_name(name):
    require(isinstance(name, str) and name and not name.startswith("/") and "\\" not in name
            and ".." not in PurePosixPath(name).parts and str(PurePosixPath(name)) == name,
            "bootstrap-entry-invalid")
    return name


def bootstrap_inventory(root):
    """Existing generated dependencies are explicit private inputs, not Git source."""
    build = root / "postgis-bootstrap/build"
    require(build.is_dir() and not build.is_symlink(), "bootstrap-build-required")
    info = build.stat()
    require(info.st_uid in (0, os.getuid()) and not info.st_mode & 0o022, "bootstrap-input-type-or-permissions")
    inventory, total = {}, 0
    for parent, children, files in os.walk(build):
        for name in (*children, *files):
            path = Path(parent) / name
            info = path.lstat()
            require(not path.is_symlink() and info.st_uid in (0, os.getuid()) and not info.st_mode & 0o022
                    and (stat.S_ISDIR(info.st_mode) if name in children else stat.S_ISREG(info.st_mode)),
                    "bootstrap-input-type-or-permissions")
            artifact_name(path.relative_to(build).as_posix())
        for name in files:
            path = Path(parent) / name
            total += path.stat().st_size
            require(total <= MAX_ARTIFACT_BYTES and len(inventory) < 4096, "bootstrap-size-limit")
            inventory[path.relative_to(build).as_posix()] = {"sha256": digest(path.read_bytes()), "size": path.stat().st_size}
    require("handler.py" in inventory and inventory["handler.py"]["sha256"] ==
            digest((root / "postgis-bootstrap/handler.py").read_bytes()), "bootstrap-handler-source-mismatch")
    return inventory


def module_inventory(root, repository):
    """Bind the initialized third-party module tree without publishing its bytes."""
    cache = root / ".terraform/modules"
    index_path = cache / "modules.json"
    require(cache.is_dir() and not cache.is_symlink() and index_path.is_file()
            and not index_path.is_symlink(), "module-cache-required")
    for directory in (cache.parent, cache):
        info = directory.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid in (0, os.getuid())
                and not info.st_mode & 0o022, "module-cache-type-or-permissions")
    index_bytes = index_path.read_bytes()
    require(len(index_bytes) <= MAX_ARTIFACT_BYTES, "module-cache-size-limit")
    index = json.loads(index_bytes)
    require(isinstance(index.get("Modules"), list) and index["Modules"], "module-index-invalid")
    modules, keys, remote = [], set(), 0
    local_roots = (root, repository / "infrastructure/terraform/modules",
                   repository / "infrastructure/terraform/components")
    for item in index["Modules"]:
        require(isinstance(item, dict) and all(isinstance(item.get(key), str)
                for key in ("Key", "Source", "Dir")), "module-index-invalid")
        key, source, location = (item[name] for name in ("Key", "Source", "Dir"))
        require(key not in keys and location and not Path(location).is_absolute(), "module-index-invalid")
        keys.add(key)
        version = item.get("Version")
        require(version is None or isinstance(version, str) and version, "module-index-invalid")
        directory = (root / location).resolve()
        require(directory.is_dir() and (directory == cache or cache in directory.parents
                or any(directory == local or local in directory.parents for local in local_roots)),
                "module-location-invalid")
        registry_host, separator, _ = source.partition("/")
        if registry_host == "registry.terraform.io" and separator:
            require(version is not None and cache in directory.parents, "module-location-invalid")
        if key and cache in directory.parents:
            remote += 1
        modules.append({"key": key, "source": source, "version": version, "dir": location})
    require(remote > 0, "module-cache-required")

    files, links, total, entries = {}, {}, 0, 0
    for parent, children, names in os.walk(
            cache, followlinks=False, onerror=lambda _: require(False, "module-cache-unreadable")):
        for name in (*children, *names):
            entries += 1
            require(entries <= 32768, "module-cache-size-limit")
            path = Path(parent) / name
            relative = path.relative_to(cache).as_posix()
            artifact_name(relative)
            info = path.lstat()
            require(info.st_uid in (0, os.getuid()), "module-cache-type-or-permissions")
            if path.is_symlink():
                target = path.resolve(strict=True)
                require(target.is_dir() and any(target == local or local in target.parents
                        for local in local_roots) and repository in target.parents,
                        "module-cache-symlink-refused")
                links[relative] = target.relative_to(repository).as_posix()
                if name in children:
                    children.remove(name)
            elif name in children:
                require(stat.S_ISDIR(info.st_mode) and not info.st_mode & 0o022,
                        "module-cache-type-or-permissions")
            else:
                require(stat.S_ISREG(info.st_mode) and not info.st_mode & 0o022,
                        "module-cache-type-or-permissions")
                total += info.st_size
                require(total <= MAX_MODULE_BYTES and len(files) < 16384, "module-cache-size-limit")
                content = path.read_bytes()
                require(len(content) == info.st_size, "module-cache-drift")
                files[relative] = {"sha256": digest(content), "size": info.st_size}
    require("modules.json" in files and files["modules.json"]["sha256"] == digest(index_bytes),
            "module-index-invalid")
    for module in modules:
        directory = (root / module["dir"]).resolve()
        if cache in directory.parents:
            prefix = directory.relative_to(cache).as_posix() + "/"
            require(any(name.startswith(prefix) and name.endswith((".tf", ".tf.json"))
                    for name in files), "module-cache-incomplete")
    return {"schema": "honua.aws-cert-module-inputs/v2", "modulesJsonSha256": digest(index_bytes),
            "modules": sorted(modules, key=lambda item: item["key"]), "files": files, "links": links}


def provider_inventory(root):
    """Verify unpacked provider packages against committed h1 lock checksums."""
    cache = root / ".terraform/providers"
    require(cache.is_dir() and not cache.is_symlink(), "provider-cache-required")
    lock = (root / ".terraform.lock.hcl").read_text()
    blocks = re.findall(r'^provider "([^"]+)" \{(.*?)^\}', lock, re.MULTILINE | re.DOTALL)
    require(blocks and len(blocks) == len(re.findall(r'^provider "', lock, re.MULTILINE)),
            "provider-lock-invalid")
    platform = "linux_amd64"
    require(sys.platform == "linux" and os.uname().machine == "x86_64", "provider-platform-unsupported")
    result, total, count = [], 0, 0
    for address, body in blocks:
        require(re.fullmatch(r"registry\.terraform\.io/[a-z0-9-]+/[a-z0-9-]+", address),
                "provider-lock-invalid")
        versions = re.findall(r'^\s*version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', body, re.MULTILINE)
        hashes = set(re.findall(r'"(h1:[A-Za-z0-9+/]{43}=)"', body))
        require(len(versions) == 1 and hashes, "provider-lock-invalid")
        location = cache / address / versions[0] / platform
        require(location.is_dir(), "provider-cache-required")
        target = location.resolve(strict=True)
        require(target.is_dir(), "provider-cache-type-or-permissions")
        for path in (location, target):
            for node in (path, *path.parents):
                info = node.lstat()
                linked_package = node == location and stat.S_ISLNK(info.st_mode)
                require(info.st_uid in (0, os.getuid())
                        and (linked_package or stat.S_ISDIR(info.st_mode))
                        and (linked_package or not info.st_mode & 0o022
                             or (info.st_uid == 0 and info.st_mode & stat.S_ISVTX)),
                        "provider-cache-type-or-permissions")
        files = {}
        for parent, children, names in os.walk(target, followlinks=False,
                                                onerror=lambda _: require(False, "provider-cache-unreadable")):
            parent_path = Path(parent)
            for name in (*children, *names):
                path = parent_path / name
                relative = path.relative_to(target).as_posix()
                artifact_name(relative)
                count += 1
                require(count <= 4096, "provider-cache-size-limit")
                info = path.lstat()
                require(info.st_uid in (0, os.getuid()) and not info.st_mode & 0o022
                        and not stat.S_ISLNK(info.st_mode), "provider-cache-type-or-permissions")
                if name in children:
                    require(stat.S_ISDIR(info.st_mode), "provider-cache-type-or-permissions")
                    continue
                require(stat.S_ISREG(info.st_mode), "provider-cache-type-or-permissions")
                total += info.st_size
                require(total <= MAX_PROVIDER_BYTES, "provider-cache-size-limit")
                content_hash = hashlib.sha256()
                with path.open("rb") as stream:
                    before = os.fstat(stream.fileno())
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        content_hash.update(chunk)
                    after = os.fstat(stream.fileno())
                require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                        == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
                        "provider-cache-drift")
                files[relative] = {"sha256": content_hash.hexdigest(), "size": info.st_size,
                                   "mode": stat.S_IMODE(info.st_mode)}
        name = address.rsplit("/", 1)[-1]
        require(any(file.startswith("terraform-provider-" + name) and data["mode"] & 0o111
                    for file, data in files.items()), "provider-cache-incomplete")
        # Terraform uses Go dirhash.Hash1 for unpacked packages: sorted file
        # names, hex SHA256, two spaces, name, newline, then base64 SHA256.
        summary = "".join(f'{files[file]["sha256"]}  {file}\n'
                          for file in sorted(files, key=lambda value: value.encode())).encode()
        package_hash = "h1:" + base64.b64encode(hashlib.sha256(summary).digest()).decode()
        require(package_hash in hashes, "provider-checksum-mismatch")
        result.append({"address": address, "version": versions[0], "platform": platform,
                       "packageHash": package_hash, "cachePath": str(location),
                       "resolvedPath": str(target), "files": files})
    return sorted(result, key=lambda value: value["address"])


def bootstrap_zip_inventory(data):
    require(len(data) <= MAX_ARTIFACT_BYTES, "bootstrap-size-limit")
    inventory, total = {}, 0
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        require(len(archive.infolist()) <= 4096, "bootstrap-size-limit")
        names = set()
        for member in archive.infolist():
            name = artifact_name(member.filename.rstrip("/") if member.is_dir() else member.filename)
            require(name not in names and not member.flag_bits & 1, "bootstrap-entry-invalid")
            names.add(name)
            mode = stat.S_IFMT(member.external_attr >> 16)
            require(mode in ((0, stat.S_IFDIR) if member.is_dir() else (0, stat.S_IFREG)), "bootstrap-entry-invalid")
            if member.is_dir():
                continue
            total += member.file_size
            require(0 <= member.file_size <= MAX_ARTIFACT_BYTES and total <= MAX_ARTIFACT_BYTES,
                    "bootstrap-size-limit")
            content = archive.read(member)
            inventory[name] = {"sha256": digest(content), "size": len(content)}
    return inventory


def bootstrap_plan_binding(plan, archive_sha, archive_path):
    changes = {item["address"]: item["change"] for item in plan["resource_changes"]}
    require(changes[BOOTSTRAP_BUILD]["actions"] == ["no-op"], "bootstrap-deferred-build-refused")
    # An archive read deferred to apply can repackage different bytes later.
    require(BOOTSTRAP_ARCHIVE not in changes or changes[BOOTSTRAP_ARCHIVE]["actions"] == ["no-op"],
            "bootstrap-deferred-archive-refused")
    expected = base64.b64encode(bytes.fromhex(archive_sha)).decode()
    # path.module in the root module is normally "."; admit only these exact
    # equivalent spellings of the fixed protected path, never caller paths.
    paths = {archive_path, "postgis-bootstrap/bootstrap.zip", "./postgis-bootstrap/bootstrap.zip"}
    function = changes[BOOTSTRAP_FUNCTION]
    require(function["after"]["filename"] in paths and function["after"]["source_code_hash"] == expected
            and not function.get("after_unknown", {}).get("source_code_hash", False), "bootstrap-plan-hash-mismatch")
    resources = {item["address"]: item["values"] for item in plan["planned_values"]["root_module"]["resources"]}
    require(resources[BOOTSTRAP_ARCHIVE]["output_base64sha256"] == expected
            and resources[BOOTSTRAP_ARCHIVE]["output_path"] in paths
            and resources[BOOTSTRAP_FUNCTION]["filename"] in paths
            and resources[BOOTSTRAP_FUNCTION]["source_code_hash"] == expected, "bootstrap-plan-hash-mismatch")


def retain_bootstrap(commands, root, packet, before):
    require(bootstrap_inventory(root) == before, "bootstrap-build-drift")
    path = root / "postgis-bootstrap/bootstrap.zip"
    info = path.lstat()
    require(not path.is_symlink() and stat.S_ISREG(info.st_mode) and info.st_uid in (0, os.getuid())
            and not info.st_mode & 0o022 and info.st_size <= MAX_ARTIFACT_BYTES, "bootstrap-archive-invalid")
    content = path.read_bytes()
    require(bootstrap_zip_inventory(content) == before, "bootstrap-archive-input-mismatch")
    archive_sha = digest(content)
    plan = commands.json(["terraform", "-chdir=" + str(root), "show", "-json", str(packet / "plan.bin")])
    bootstrap_plan_binding(plan, archive_sha, str(path))
    write(packet / "bootstrap.zip", content)
    write(packet / "bootstrap-inputs.json", {"schema": "honua.aws-cert-bootstrap-artifact/v1",
          "files": before, "archiveSha256": archive_sha, "buildActions": ["no-op"],
          "sourceCodeHash": base64.b64encode(bytes.fromhex(archive_sha)).decode()})
    require(path.read_bytes() == content and bootstrap_inventory(root) == before, "bootstrap-build-drift")


def produce(request_path, repository):
    os.umask(0o077)
    request = load(protected(request_path))
    require(request["schema"] == "honua.aws-cert-plan-request/v1", "request-schema-invalid")
    require(request["targetId"] == "aws-cert" and text(request["actorId"]), "target-invalid")
    require(re.fullmatch(r"[0-9a-f]{40}", request["iacRevision"])
            and re.fullmatch(SHA, request["candidateDigest"]), "source-pin-invalid")
    now = datetime.now(timezone.utc)
    lifetime = request["expiresInSeconds"]
    require(type(lifetime) is int and 60 <= lifetime <= 1800, "expiry-invalid")
    require(type(request["planTimeoutSeconds"]) is int and 60 <= request["planTimeoutSeconds"] <= 1800,
            "plan-timeout-invalid")
    require(timestamp(request["sessionExpiresAtUtc"]) > now + timedelta(seconds=lifetime + 120), "session-expiring")
    retention = request["privateRetention"]
    require(text(retention["owner"]) and text(retention["accessReference"])
            and timestamp(retention["retainUntilUtc"]) > now + timedelta(seconds=lifetime), "private-retention-required")
    parent = protected(retention["directory"], directory=True)
    require(repository not in parent.parents and parent != repository, "private-packet-in-source")
    root = repository / ROOT_REL
    require(root.is_dir() and not root.is_symlink(), "root-invalid")
    require(not any(p.is_symlink() for p in (root, *root.parents)), "root-invalid")
    backend_role, deploy_role = contracts(request)
    var_file = protected(request["varFile"])
    require(digest(var_file.read_bytes()) == request["varFileSha256"], "input-file-mismatch")
    variables = load(var_file)
    require(variables.get("environment", "cert") == "cert"
            and variables.get("region", "us-east-1") == request["region"], "target-input-invalid")
    require(variables.get("licensing_mode") == "Disabled" and variables.get("enable_pro_license") is False
            and not any(variables.get(k) for k in variables if k.startswith("pro_license_")), "licensing-input-invalid")
    required_images = {"honua_image", "gp_batch_image"}
    if variables.get("enable_customcode_batch"):
        required_images.update(("customcode_batch_image", "customcode_dotnet_batch_image"))
    if variables.get("enable_ecs_alb_cert"):
        required_images.add("ecs_alb_image")
    images = {k: variables[k] for k in IMAGE_KEYS if variables.get(k)}
    require(required_images <= images.keys() and images == request["imagePins"]
            and all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]+@sha256:" + SHA, v)
                    for v in images.values()), "image-input-invalid")
    for key in ("audit_chain_key_secret_arn", "operation_key_ring_certificate_secret_arn"):
        require(variables.get(key) == request["secretReferences"][key]
                and re.fullmatch(rf"arn:aws:secretsmanager:{request['region']}:{request['accountId']}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{{6}}", variables[key]),
                "secret-reference-invalid")
    # Hidden auto inputs would undermine the explicitly approved proposal.
    auto = [*root.glob("*.auto.tfvars*"), root / "terraform.tfvars", root / "terraform.tfvars.json"]
    require(not any(p.exists() and p != var_file for p in auto), "implicit-input-refused")
    token_file = protected(request["backendTokenFile"])
    token = token_file.read_text().strip().split(".")
    require(len(token) == 3, "backend-token-invalid")
    claims = json.loads(base64.urlsafe_b64decode(token[1] + "=" * (-len(token[1]) % 4)))
    require(claims["iss"] == ISSUER and claims["sub"] == SUBJECT and claims["aud"] == AUDIENCE
            and claims["exp"] > (now + timedelta(seconds=lifetime + 120)).timestamp(), "backend-token-invalid")
    env = environment(request, root)
    # Inspect the existing descriptor, never init/reconfigure it. A raw token in
    # descriptor config is refused by the maintained substrate as well.
    backend_file = root / ".terraform/terraform.tfstate"
    validate_backend_descriptor_path(backend_file)
    config = load(backend_file)["backend"]["config"]
    validate_backend_transport(config)
    web = config.get("assume_role_with_web_identity") or {}
    require(web.get("role_arn") == backend_role and web.get("web_identity_token_file") == str(token_file)
            and not config.get("assume_role") and not config.get("role_arn"), "backend-web-identity-required")
    packet = parent / ("aws-cert-plan-" + uuid.uuid4().hex)
    packet.mkdir(mode=0o700)
    cli_directory = tempfile.TemporaryDirectory(prefix=".cert-cli-", dir=parent)
    cli_config = Path(cli_directory.name) / "terraform.tfrc"
    write(cli_config, b"")
    # An owned empty config supersedes ~/.terraformrc without changing HOME or
    # loading provider dev_overrides/credential helpers from ambient config.
    env["TF_CLI_CONFIG_FILE"] = str(cli_config)
    commands = Commands(repository, packet, env)
    try:
        write(packet / "request.json", request)
        require(commands.run(["git", "rev-parse", "HEAD"]).decode().strip() == request["iacRevision"], "source-mismatch")
        require(not commands.run(["git", "status", "--porcelain", "--untracked-files=normal"]).strip(), "source-dirty")
        validate_runtime_source(commands, root, repository, config)
        require(digest((root / ".terraform.lock.hcl").read_bytes()) == request["providerLockSha256"], "provider-lock-mismatch")
        provider_before = provider_inventory(root)
        require(commands.json(["terraform", "version", "-json"])["terraform_version"] == request["terraformVersion"], "toolchain-mismatch")
        trust(commands, deploy_role, request["accountId"])
        trust(commands, backend_role, request["accountId"])
        bootstrap_before = bootstrap_inventory(root)
        modules_before = module_inventory(root, repository)
        modules_before["providers"] = provider_before
        archive_path = root / "postgis-bootstrap/bootstrap.zip"
        if archive_path.exists() or archive_path.is_symlink():
            require(not archive_path.is_symlink() and archive_path.is_file(), "bootstrap-archive-invalid")
        before = commands.facts(root)
        validate_facts(before, request, deploy_role)
        write(packet / "context-before.json", before)
        commands.run(["bash", "scripts/terraform-exact-plan.sh", "--root", str(root), "--action", "apply",
                      "--skip-init", "--var-file", str(var_file), "--plan-out", str(packet / "plan.bin"),
                      "--metadata-out", str(packet / "metadata.json"), "--expires-in", str(lifetime),
                      "--actor", request["actorId"], "--target-id", "aws-cert",
                      "--candidate-digest", request["candidateDigest"], "--workload-identity-digest",
                      request["workloadIdentityContractDigest"]], seconds=planning_seconds(request, claims))
        retain_bootstrap(commands, root, packet, bootstrap_before)
        require(provider_inventory(root) == provider_before, "provider-cache-drift")
        modules_after = module_inventory(root, repository)
        modules_after["providers"] = provider_before
        require(modules_after == modules_before, "module-cache-drift")
        write(packet / "module-inputs.json", modules_before)
        after = commands.facts(root)
        validate_facts(after, request, deploy_role)
        require(after == before and digest(var_file.read_bytes()) == request["varFileSha256"], "context-drift")
        write(packet / "context-after.json", after)
        metadata = load(packet / "metadata.json")
        md = dict(metadata)
        binding = md.pop("plan_metadata_digest")
        require(binding == digest(canonical(md)) and metadata["plan"]["sha256"] == digest((packet / "plan.bin").read_bytes())
                and metadata["action"] == "apply" and metadata["target_id"] == "aws-cert"
                and metadata["candidate_digest"] == request["candidateDigest"]
                and metadata["posture"]["release_qualified"] is True
                and metadata["qualification_status"] == "unqualified"
                and metadata["inputs"] == before["inputs"]
                and metadata["source"] == before["source"]
                and metadata["state_before"] == before["state"]
                and metadata["workload_identity_contract_digest"] == request["workloadIdentityContractDigest"]
                and metadata["toolchain"] == {"terraform_version": request["terraformVersion"],
                                             "provider_lock_digest": request["providerLockSha256"]}
                and metadata["backend"]["backend_config_digest"] == request["backend"]["configDigest"]
                and metadata["identity"]["assumed_role_arn"] == before["identity"]["arn"], "plan-binding-invalid")
        validate_expiry(metadata, request, claims, now)
        with (packet / "review.txt").open("xb") as output:
            commands.run(["terraform", "-chdir=" + str(root), "show", "-no-color", str(packet / "plan.bin")], output=output)
        require(not commands.run(["git", "status", "--porcelain", "--untracked-files=normal"]).strip()
                and commands.run(["git", "rev-parse", "HEAD"]).decode().strip() == request["iacRevision"], "source-drift")
        validate_runtime_source(commands, root, repository, config)
        require(provider_inventory(root) == provider_before, "provider-cache-drift")
        modules_after = module_inventory(root, repository)
        modules_after["providers"] = provider_before
        require(modules_after == modules_before, "module-cache-drift")
        files = {}
        require({p.name for p in packet.iterdir()} == PACKET_FILES, "packet-files-invalid")
        for path in packet.iterdir():
            protected(path)
            files[path.name] = digest(path.read_bytes())
            with path.open("rb") as stream:
                os.fsync(stream.fileno())
        require((packet / "metadata.json.digest").read_text().strip() == binding, "plan-binding-invalid")
        write(packet / ".packet.tmp", {"schema": "honua.aws-cert-plan-packet/v1", "files": files,
              "planMetadataDigest": binding, "approvalStatus": "not-approved", "qualificationStatus": "not-evaluated"})
        # Publish only the fully written descriptor, exclusively and atomically.
        os.link(packet / ".packet.tmp", packet / "packet.json")
        (packet / ".packet.tmp").unlink()
        directory_fd = os.open(packet, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        result = verify_packet(packet, digest((packet / "packet.json").read_bytes()))
        result["status"] = "planned-unapproved"
        return result
    except BaseException:
        # Retain private diagnostics/partial plan for the custodian, but no completed packet.
        (packet / "packet.json").unlink(missing_ok=True)
        raise
    finally:
        cli_directory.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--request", type=Path)
    operation.add_argument("--verify-packet", type=Path)
    parser.add_argument("--expected-packet-sha256")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[5]
    try:
        result = (produce(args.request, repository) if args.request else
                  verify_packet(args.verify_packet, args.expected_packet_sha256))
        code = 0
    except (Refused, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired, zipfile.BadZipFile) as error:
        result = {"schema": "honua.aws-cert-plan-public/v1", "status": "refused",
                  "reason": str(error) if isinstance(error, Refused) else "invalid-or-unavailable-context",
                  "approvalStatus": "not-approved", "qualificationStatus": "not-evaluated"}
        code = 3
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
