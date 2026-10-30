#!/usr/bin/env python3
"""Offline fixed-socket exact-apply prewrite contract; no Terraform or cloud calls."""

import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "lib" / "exact-apply-prewrite-v2.py"
JOB = "job-1"
PLAN = "a" * 64
METADATA = "b" * 64
CHALLENGE = "c" * 64


class PrewriteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "private-plan-host"
        self.challenges = self.root / "challenges"
        self.challenges.mkdir(parents=True)
        self.file = self.challenges / (hashlib.sha256(JOB.encode()).hexdigest() + ".txt")
        self.file.write_text(CHALLENGE + "\n", encoding="ascii")
        self.file.chmod(0o600)
        self.socket_path = self.root / "exact-apply-prewrite.sock"
        self.environment = {
            **os.environ,
            "HONUA_IAC_EXACT_APPLY_JOB_ID": JOB,
            "HONUA_IAC_PREWRITE_PLAN_SHA256": PLAN,
            "HONUA_IAC_PREWRITE_METADATA_DIGEST": METADATA,
            "HONUA_EXACT_APPLY_HOST_ROOT": str(self.root),
            "HONUA_IAC_EXACT_APPLY_SOCKET": str(self.socket_path),
            "HONUA_IAC_EXACT_APPLY_CHALLENGE_FILE": str(self.file),
        }

    def run_callback(self):
        return subprocess.run(["python3", str(SCRIPT)], env=self.environment,
                              capture_output=True, timeout=15, check=False)

    def socket_worker(self, response):
        observed = []
        ready = threading.Event()

        def serve():
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(self.socket_path))
                listener.listen(1)
                ready.set()
                connection, _ = listener.accept()
                with connection:
                    request = bytearray()
                    while b"\n" not in request:
                        request.extend(connection.recv(1024))
                    observed.append(json.loads(request.decode("utf-8")))
                    body = response if isinstance(response, str) else json.dumps(response)
                    connection.sendall((body + "\n").encode("utf-8"))

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        self.assertTrue(ready.wait(2))
        return observed, thread

    def test_exact_authorization_allows_only_the_bound_request(self):
        response = {"schemaVersion": "honua.exact-apply-prewrite-response/v1",
                    "jobId": JOB, "authorization": "one-forward-mutation-authorized",
                    "planSha256": PLAN, "planMetadataDigest": METADATA}
        observed, thread = self.socket_worker(response)
        result = self.run_callback()
        thread.join(2)
        self.assertEqual(0, result.returncode)
        self.assertEqual(b"", result.stdout + result.stderr)
        self.assertEqual(1, len(observed))
        self.assertEqual(CHALLENGE, observed[0]["challenge"])
        self.assertEqual("honua.exact-apply-prewrite/v1", observed[0]["schemaVersion"])
        self.assertEqual(JOB, observed[0]["jobId"])
        self.assertEqual(PLAN, observed[0]["planSha256"])
        self.assertEqual(METADATA, observed[0]["planMetadataDigest"])

    def test_wrong_authorization_and_unprotected_challenge_refuse(self):
        response = {"schemaVersion": "honua.exact-apply-prewrite-response/v1",
                    "jobId": JOB, "authorization": "denied",
                    "planSha256": PLAN, "planMetadataDigest": METADATA}
        _, thread = self.socket_worker(response)
        denied = self.run_callback()
        thread.join(2)
        self.assertNotEqual(0, denied.returncode)
        self.assertEqual(b"", denied.stdout + denied.stderr)
        self.file.chmod(0o644)
        unprotected = self.run_callback()
        self.assertNotEqual(0, unprotected.returncode)
        self.assertEqual(b"", unprotected.stdout + unprotected.stderr)

    def test_duplicate_response_field_refuses(self):
        response = ('{"schemaVersion":"honua.exact-apply-prewrite-response/v1",'
                    '"jobId":"job-1","jobId":"job-1",'
                    '"authorization":"one-forward-mutation-authorized",'
                    '"planSha256":"' + PLAN + '","planMetadataDigest":"' + METADATA + '"}')
        _, thread = self.socket_worker(response)
        result = self.run_callback()
        thread.join(2)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b"", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
