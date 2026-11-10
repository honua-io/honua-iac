#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt_retry() { for attempt in 1 2 3 4 5; do apt-get "$@" && return 0; sleep $((attempt * 10)); done; return 1; }
apt_retry update
apt_retry install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL --retry 5 --retry-all-errors https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
apt_retry update
apt_retry install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker ubuntu
systemctl enable --now docker
