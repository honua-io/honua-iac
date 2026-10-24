#!/usr/bin/env python3
"""Fixed installed-host prewrite callback; never a model-selected command/path."""

import hashlib
import json
import os
import re
import socket
import stat
import sys
import time


def required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise ValueError("private host prewrite input missing")
    return value


def sha(value: str) -> bool:
    return re.fullmatch(r"[0-9a-f]{64}", value) is not None


def challenge(job_id: str, host_root: str) -> str:
    basename = hashlib.sha256(job_id.encode("utf-8")).hexdigest() + ".txt"
    filename = os.path.join(host_root, "challenges", basename)
    if required("HONUA_IAC_EXACT_APPLY_CHALLENGE_FILE") != filename:
        raise ValueError("private host challenge path changed")
    descriptor = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.geteuid() or (
            stat.S_IMODE(details.st_mode) != 0o600
        ):
            raise ValueError("private host challenge is not protected")
        with os.fdopen(descriptor, "rb", closefd=False) as source:
            data = source.read(66)
        value = data.decode("ascii").rstrip("\n")
        if len(data) > 65 or not sha(value):
            raise ValueError("private host challenge is invalid")
        return value
    finally:
        os.close(descriptor)


def callback() -> None:
    job_id = required("HONUA_IAC_EXACT_APPLY_JOB_ID")
    plan_sha = required("HONUA_IAC_PREWRITE_PLAN_SHA256")
    metadata_digest = required("HONUA_IAC_PREWRITE_METADATA_DIGEST")
    host_root = required("HONUA_EXACT_APPLY_HOST_ROOT")
    socket_path = required("HONUA_IAC_EXACT_APPLY_SOCKET")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", job_id) or not sha(plan_sha) or not sha(metadata_digest):
        raise ValueError("private host job or plan identity is invalid")
    if not os.path.isabs(host_root) or os.path.realpath(host_root) != host_root or (
        os.path.basename(host_root) != "private-plan-host"
    ):
        raise ValueError("private host root is invalid")
    if socket_path != os.path.join(host_root, "exact-apply-prewrite.sock"):
        raise ValueError("private host socket path changed")
    token = challenge(job_id, host_root)
    request = {
        "schemaVersion": "honua.exact-apply-prewrite/v1",
        "jobId": job_id,
        "planSha256": plan_sha,
        "planMetadataDigest": metadata_digest,
        "challenge": token,
    }
    encoded = (json.dumps(request, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    if len(encoded) > 4096:
        raise ValueError("private host prewrite request is oversized")
    deadline = time.monotonic() + 10

    def remaining() -> float:
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise TimeoutError("private host prewrite deadline passed")
        return seconds

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(remaining())
        connection.connect(socket_path)
        sent = 0
        while sent < len(encoded):
            connection.settimeout(remaining())
            count = connection.send(encoded[sent:])
            if count == 0:
                raise ConnectionError("private host prewrite socket closed")
            sent += count
        response = bytearray()
        while len(response) <= 4096:
            connection.settimeout(remaining())
            chunk = connection.recv(min(1024, 4097 - len(response)))
            if not chunk:
                break
            response.extend(chunk)
            if b"\n" in chunk:
                break
    if len(response) > 4096 or response.count(b"\n") != 1 or not response.endswith(b"\n"):
        raise ValueError("private host prewrite response is incomplete")
    def unique_fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("private host prewrite response repeats a field")
            result[key] = value
        return result

    result = json.loads(response.decode("utf-8"), object_pairs_hook=unique_fields)
    if not isinstance(result, dict) or set(result) != {
        "schemaVersion", "jobId", "authorization", "planSha256", "planMetadataDigest"
    } or result != {
        "schemaVersion": "honua.exact-apply-prewrite-response/v1",
        "jobId": job_id,
        "authorization": "one-forward-mutation-authorized",
        "planSha256": plan_sha,
        "planMetadataDigest": metadata_digest,
    }:
        raise ValueError("private host prewrite was not authorized")


if __name__ == "__main__":
    try:
        callback()
    except (OSError, ValueError, UnicodeError, KeyError, TypeError, json.JSONDecodeError):
        # No receipt, path, host secret, or challenge enters the wrapper log.
        sys.exit(1)
