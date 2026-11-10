# Install before network bootstrap; Ubuntu cloud images include Python 3.
cat > /usr/local/sbin/honua-build-host-idle-stop <<'PYTHON'
#!/usr/bin/env python3
from datetime import datetime, timezone
import hashlib
import hmac
import json
import re
import subprocess
import time
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from pathlib import Path

WORKTREES = Path("/home/ubuntu/wt")
LAST_ACTIVE = Path("/run/honua-build-host-last-active")
CONFIG = Path("/etc/honua-build-host.json")


def processes():
    result = subprocess.run(
        ["ps", "-eo", "etimes=,comm=,args="], check=True, capture_output=True, text=True
    )
    return [line.split(None, 2) for line in result.stdout.splitlines() if line.strip()]


def has_build(rows):
    for _, command, args in rows:
        if command == "Runner.Worker":
            return True
        if command == "dotnet" and re.search(r"\b(build|test|publish|pack|restore|msbuild|vstest)\b|MSBuild\.dll", args):
            return True
        if command in {"docker", "docker-buildx", "docker-compose", "buildctl"} and re.search(r"\b(build|bake)\b", args):
            return True
    return False


def scale_to_zero(config):
    # No downloaded SDK: this must work even if the first apt/curl fails.
    # SigV4: docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
    metadata = "http://169.254.169.254/latest/"
    token_request = Request(metadata + "api/token", method="PUT",
                            headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
    with urlopen(token_request, timeout=5) as response:
        token = response.read().decode()

    def metadata_get(path):
        request = Request(metadata + "meta-data/iam/security-credentials/" + path,
                          headers={"X-aws-ec2-metadata-token": token})
        with urlopen(request, timeout=5) as response:
            return response.read().decode()

    credentials = json.loads(metadata_get(metadata_get("").strip()))
    body = urlencode({"Action": "SetDesiredCapacity", "Version": "2011-01-01",
                      "AutoScalingGroupName": config["group"], "DesiredCapacity": "0",
                      "HonorCooldown": "false"}).encode()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    day = stamp[:8]
    host = "autoscaling." + config["region"] + ".amazonaws.com"
    headers = {"content-type": "application/x-www-form-urlencoded", "host": host,
               "x-amz-date": stamp, "x-amz-security-token": credentials["Token"]}
    signed_headers = ";".join(sorted(headers))
    canonical_headers = "".join(name + ":" + headers[name] + "\n" for name in sorted(headers))
    canonical = "\n".join(["POST", "/", "", canonical_headers, signed_headers,
                            hashlib.sha256(body).hexdigest()])
    scope = day + "/" + config["region"] + "/autoscaling/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", stamp, scope,
                          hashlib.sha256(canonical.encode()).hexdigest()])
    key = ("AWS4" + credentials["SecretAccessKey"]).encode()
    for part in (day, config["region"], "autoscaling", "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    headers["Authorization"] = ("AWS4-HMAC-SHA256 Credential=" + credentials["AccessKeyId"]
                                + "/" + scope + ", SignedHeaders=" + signed_headers
                                + ", Signature=" + signature)
    with urlopen(Request("https://" + host + "/", data=body, headers=headers), timeout=15):
        pass


def main():
    config = json.loads(CONFIG.read_text())
    idle_seconds = config["idle_seconds"]
    now = int(time.monotonic())
    rows = processes()
    if any(WORKTREES.glob("*/.honua-active.*")) or has_build(rows):
        LAST_ACTIVE.write_text(str(now))
        return
    if any(int(age) < idle_seconds and command in {"sshd", "sshd-session"} and "@" in args
           for age, command, args in rows):
        return
    last_active = int(LAST_ACTIVE.read_text()) if LAST_ACTIVE.exists() else 0
    if now - last_active >= idle_seconds:
        scale_to_zero(config)


if __name__ == "__main__":
    main()
PYTHON
chmod 0755 /usr/local/sbin/honua-build-host-idle-stop

cat > /etc/systemd/system/honua-build-host-idle-stop.service <<'SERVICE'
[Unit]
Description=Stop the idle Honua build host

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/honua-build-host-idle-stop
SERVICE

cat > /etc/systemd/system/honua-build-host-idle-stop.timer <<'TIMER'
[Unit]
Description=Check build host activity every five minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now honua-build-host-idle-stop.timer
