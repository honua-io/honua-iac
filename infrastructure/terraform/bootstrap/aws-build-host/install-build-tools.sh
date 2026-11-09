# Appended after shared/install-docker.sh, which defines apt_retry and sets strict mode.
apt_retry install -y git rsync python3 python3-venv unzip jq
curl -fsSL --retry 5 --retry-all-errors https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
sudo -u ubuntu bash /tmp/dotnet-install.sh --channel 10.0 --install-dir /home/ubuntu/.dotnet
echo 'export PATH=/home/ubuntu/.dotnet:$PATH DOTNET_ROOT=/home/ubuntu/.dotnet DOTNET_CLI_TELEMETRY_OPTOUT=1' > /etc/profile.d/dotnet.sh
curl -fsSL --retry 5 --retry-all-errors https://deb.nodesource.com/setup_22.x | bash -
apt_retry install -y nodejs

cat > /usr/local/sbin/honua-build-host-idle-stop <<'PYTHON'
#!/usr/bin/env python3
import re
import subprocess
import time
from pathlib import Path

WORKTREES = Path("/home/ubuntu/wt")
LAST_ACTIVE = Path("/run/honua-build-host-last-active")
IDLE_SECONDS = 30 * 60


def processes():
    result = subprocess.run(
        ["ps", "-eo", "etimes=,comm=,args="], check=True, capture_output=True, text=True
    )
    return [line.split(None, 2) for line in result.stdout.splitlines() if line.strip()]


def has_build(rows):
    for _, command, args in rows:
        if command == "dotnet":
            return True
        if command in {"docker", "docker-buildx", "docker-compose", "buildctl"} and re.search(r"\b(build|bake)\b", args):
            return True
    return False


def main():
    now = int(time.monotonic())
    rows = processes()
    if any(WORKTREES.glob("*/.honua-active.*")) or has_build(rows):
        LAST_ACTIVE.write_text(str(now))
        return
    if any(int(age) < IDLE_SECONDS and command in {"sshd", "sshd-session"} and "@" in args
           for age, command, args in rows):
        return
    last_active = int(LAST_ACTIVE.read_text()) if LAST_ACTIVE.exists() else 0
    if now - last_active >= IDLE_SECONDS:
        subprocess.run(["shutdown", "-h", "now"], check=True)


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
