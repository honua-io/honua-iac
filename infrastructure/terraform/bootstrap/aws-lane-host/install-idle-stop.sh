#!/usr/bin/env bash
set -euo pipefail
# The Python probe is written by user data before this installer runs.
chmod 0755 /usr/local/sbin/honua-lane-idle-stop
cat > /etc/tmpfiles.d/honua-lane-activity.conf <<'LOCK'
f /run/lock/honua-lane-activity.lock 0644 root root -
LOCK
systemd-tmpfiles --create /etc/tmpfiles.d/honua-lane-activity.conf
cat > /etc/systemd/system/honua-lane-idle-stop.service <<'SERVICE'
[Unit]
Description=Stop the lane host after continuous inactivity
After=cloud-final.service
RequiresMountsFor=/home/ubuntu/lanes

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/honua-lane-idle-stop
TimeoutStartSec=90
SERVICE
cat > /etc/systemd/system/honua-lane-idle-stop.timer <<'TIMER'
[Unit]
Description=Check lane host activity every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
TIMER
# A controller installed on the retained volume can resume after replacement.
keeper=/home/ubuntu/lanes/host-services/honua-lane-keeper.service
if [ -f "$keeper" ]; then
  install -m 0644 "$keeper" /etc/systemd/system/honua-lane-keeper.service
  systemctl enable honua-lane-keeper.service
  systemctl start --no-block honua-lane-keeper.service
fi
systemctl daemon-reload
systemctl enable --now honua-lane-idle-stop.timer
