# Appended after shared/install-docker.sh, which defines apt_retry and sets strict mode.
# Lane scripts use absolute /home/mike paths from the operator workstation, so /home/mike points at
# the persistent data volume and the ubuntu account runs every lane.
apt_retry install -y git rsync python3 python3-venv jq unzip tmux
config=/etc/honua-lane-host.json
setting() { jq -r ".$1" "$config"; }
volume_id=$(setting data_volume_id)
lanes=/home/ubuntu/lanes
home=/home/mike

device=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${volume_id//-/}
for _ in $(seq 1 120); do [ -e "$device" ] && break; sleep 5; done
[ -e "$device" ] || { echo "data volume $volume_id never attached" >&2; exit 1; }
blkid "$device" >/dev/null 2>&1 || mkfs.ext4 -q -L honua-lanes "$device"
uuid=$(blkid -s UUID -o value "$device")
install -d "$lanes"
grep -q "$uuid" /etc/fstab || echo "UUID=$uuid $lanes ext4 defaults,nofail,x-systemd.device-timeout=120 0 2" >> /etc/fstab
systemctl daemon-reload
mountpoint -q "$lanes" || mount "$lanes"
chown ubuntu:ubuntu "$lanes"

install -d -o ubuntu -g ubuntu "$lanes/home"
ln -sfn "$lanes/home" "$home"
for directory in .claude .config .config/gh .local .local/bin .local/opt honua-io; do
  install -d -o ubuntu -g ubuntu "$home/$directory"
done
install -d -m 700 -o ubuntu -g ubuntu "$home/.ssh"
# Either HOME sees the same Claude, GitHub and SSH credentials.
sudo -u ubuntu mkdir -p /home/ubuntu/.config
for entry in .claude .config/gh .gitconfig; do sudo -u ubuntu ln -sfn "$home/$entry" "/home/ubuntu/$entry"; done
sudo -u ubuntu ln -sfn "$home/.ssh/honua-build" /home/ubuntu/.ssh/honua-build
echo lane-host > /etc/honua-lane-role

curl -fsSL --retry 5 --retry-all-errors https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
curl -fsSL --retry 5 --retry-all-errors https://deb.nodesource.com/setup_22.x | bash -
apt_retry install -y gh nodejs

for attempt in 1 2 3 4 5; do
  curl -fsSL --retry 5 --retry-all-errors https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip \
    && unzip -q -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update && break
  sleep $((attempt * 10))
done
command -v aws >/dev/null

npm install -g "@anthropic-ai/claude-code@$(setting claude_code_version)"
sudo -u ubuntu ln -sfn "$(command -v claude)" "$home/.local/bin/claude"

rtk_version=$(setting rtk_version)
curl -fsSL --retry 5 --retry-all-errors -o /tmp/rtk.tar.gz \
  "https://github.com/rtk-ai/rtk/releases/download/v$rtk_version/rtk-x86_64-unknown-linux-musl.tar.gz"
echo "$(setting rtk_sha256)  /tmp/rtk.tar.gz" | sha256sum -c -
install -d -o ubuntu -g ubuntu "$home/.local/opt/rtk-$rtk_version"
tar -xzf /tmp/rtk.tar.gz -C "$home/.local/opt/rtk-$rtk_version"
chown -R ubuntu:ubuntu "$home/.local/opt/rtk-$rtk_version"

# Lane dotnet shims run read-only MSBuild queries locally; builds go to the build host.
curl -fsSL --retry 5 --retry-all-errors https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
sudo -u ubuntu bash /tmp/dotnet-install.sh --channel 10.0 --install-dir "$home/.dotnet" >/dev/null
sudo -u ubuntu ln -sfn "$home/.dotnet/dotnet" "$home/.local/bin/dotnet"
echo "export PATH=$home/.local/bin:$home/.dotnet:\$PATH DOTNET_ROOT=$home/.dotnet DOTNET_CLI_TELEMETRY_OPTOUT=1" > /etc/profile.d/honua-lane.sh

cat > /usr/local/sbin/honua-lane-secrets <<'SECRETS'
#!/bin/bash
# Writes lane credentials from SSM SecureString parameters. Claude Code rotates its login in place,
# so an existing login is kept unless --replace-claude is passed.
set -euo pipefail
config=/etc/honua-lane-host.json
region=$(jq -r .region "$config"); prefix=$(jq -r .parameter_prefix "$config"); home=/home/mike
fetch() { aws ssm get-parameter --region "$region" --name "$prefix/$1" --with-decryption --output json | jq -r .Parameter.Value; }
write_secret() {
  (umask 077 && fetch "$1" > "$2.new")
  chown ubuntu:ubuntu "$2.new" && mv "$2.new" "$2"
}
if [ ! -s "$home/.claude/.credentials.json" ] || [ "${1:-}" = --replace-claude ]; then
  write_secret claude-credentials "$home/.claude/.credentials.json"
fi
write_secret build-ssh-key "$home/.ssh/honua-build"
fetch github-token | sudo -u ubuntu env HOME="$home" gh auth login --hostname github.com --git-protocol https --with-token
sudo -u ubuntu env HOME="$home" gh auth setup-git --hostname github.com
SECRETS
chmod 755 /usr/local/sbin/honua-lane-secrets
cat > /etc/systemd/system/honua-lane-secrets.service <<'UNIT'
[Unit]
Description=Write Honua lane credentials from SSM Parameter Store
Wants=network-online.target
After=network-online.target
RequiresMountsFor=/home/ubuntu/lanes

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/honua-lane-secrets

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now honua-lane-secrets.service
