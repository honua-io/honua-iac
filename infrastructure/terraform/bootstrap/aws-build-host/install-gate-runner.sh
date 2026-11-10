# Appended after install-build-tools.sh when gate_runner_enabled is true.
# Each PR Gate runner is an unprivileged account with its own rootless Docker. Before
# every job it gets a pristine home, a fresh daemon, no route to instance metadata and
# a just-in-time registration valid for exactly one job.
gate_config=/etc/honua-gate-runner.json
gate() { jq -r ".$1" "$gate_config"; }

snap install aws-cli --classic
. /etc/os-release
curl -fsSL --retry 5 --retry-all-errors "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -o /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
# GitHub CLI's signed official repository supplies the admission checks' gh command.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 5 --retry-all-errors https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
  "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list
# Runner-enabled hosts need Node 24 for the managed artifact action's npm dependencies.
curl -fsSL --retry 5 --retry-all-errors https://deb.nodesource.com/setup_24.x | bash -
apt_retry update
apt_retry install -y gh nodejs zip zstd xz-utils locales tzdata powershell uidmap slirp4netns dbus-user-session docker-ce-rootless-extras python3-pip python3-yaml

# Ubuntu 24.04 confines unprivileged user namespaces; rootless Docker needs this exception.
cat > /etc/apparmor.d/usr.bin.rootlesskit <<'APPARMOR'
abi <abi/4.0>,
include <tunables/global>

/usr/bin/rootlesskit flags=(unconfined) {
  userns,
  include if exists <local/usr.bin.rootlesskit>
}
APPARMOR
apparmor_parser -r /etc/apparmor.d/usr.bin.rootlesskit
chmod 0750 /home/ubuntu

runner_archive=/tmp/actions-runner.tar.gz
curl -fsSL --retry 5 --retry-all-errors -o "$runner_archive" \
  "https://github.com/actions/runner/releases/download/v$(gate runner_version)/actions-runner-linux-x64-$(gate runner_version).tar.gz"
echo "$(gate runner_sha256)  ${runner_archive}" | sha256sum --check --strict
install -d -m 0755 /opt/actions-runner
tar -xzf "$runner_archive" -C /opt/actions-runner
/opt/actions-runner/bin/installdependencies.sh

cat > /usr/local/sbin/honua-gate-runner-prepare <<'PREPARE'
#!/bin/bash
# Runs as root before each job of runner $1.
set -euo pipefail
index="$1"
user="gate-runner-${index}"
uid="$(id -u "$user")"
home="/home/${user}"
config=/etc/honua-gate-runner.json
setting() { jq -r ".$1" "$config"; }

# Container users map to the account's subordinate UIDs, so their files count as the job's too.
end_previous_job() {
  local sub_start sub_count
  systemctl stop "user@${uid}.service"
  pkill -KILL -u "$user" || true
  IFS=: read -r _ sub_start sub_count < <(grep "^${user}:" /etc/subuid)
  find /tmp /var/tmp /dev/shm -xdev -mindepth 1 \( -user "$user" -o \
    \( -uid "+$((sub_start - 1))" -uid "-$((sub_start + sub_count))" \) \) -delete 2>/dev/null || true
}

restore_pristine_home() {
  find "$home" -mindepth 1 -delete
  rsync -a --chown="${user}:${user}" "/var/lib/honua-gate-runner/home-${index}/" "${home}/"
  cp -a /opt/actions-runner "${home}/runner"
  chown -R "${user}:${user}" "${home}/runner"
  systemctl start "user@${uid}.service"
  for _ in $(seq 1 60); do
    [[ -S "/run/user/${uid}/docker.sock" ]] && return 0
    sleep 1
  done
  echo "Rootless Docker for ${user} did not start." >&2
  return 1
}

block_instance_metadata() {
  local rule=(OUTPUT -m owner --uid-owner "$uid" -d 169.254.0.0/16 -j REJECT)
  iptables -C "${rule[@]}" 2>/dev/null || iptables -I "${rule[@]}"
  local rule6=(OUTPUT -m owner --uid-owner "$uid" -d fd00:ec2::254/128 -j REJECT)
  ip6tables -C "${rule6[@]}" 2>/dev/null || ip6tables -I "${rule6[@]}"
}

base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

github() {
  curl -fsS --retry 3 -H "@$1" -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' "${@:2}"
}

# Credentials travel in root-only files, never in process arguments.
register_for_one_job() {
  local secrets credentials header payload signature installation group_id request imds instance
  secrets="$(mktemp -d -p /run)"
  trap 'rm -rf "$secrets"' RETURN
  /snap/bin/aws ssm get-parameter --region "$(setting region)" --name "$(setting app_parameter)" \
    --with-decryption --query Parameter.Value --output text > "${secrets}/app.json"
  jq -r .private_key "${secrets}/app.json" > "${secrets}/key.pem"
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | base64url)"
  payload="$(jq -cn --arg app "$(jq -r .app_id "${secrets}/app.json")" --argjson now "$(date +%s)" \
    '{iat: ($now - 60), exp: ($now + 540), iss: $app}' | base64url)"
  signature="$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "${secrets}/key.pem" -binary | base64url)"
  printf 'Authorization: Bearer %s.%s.%s\n' "$header" "$payload" "$signature" > "${secrets}/app-auth"
  installation="$(github "${secrets}/app-auth" "https://api.github.com/orgs/$(setting org)/installation" | jq -r .id)"
  github "${secrets}/app-auth" -X POST -d '{"permissions":{"organization_self_hosted_runners":"write"}}' \
    "https://api.github.com/app/installations/${installation}/access_tokens" |
    jq -r '"Authorization: Bearer " + .token' > "${secrets}/runner-auth"
  group_id="$(github "${secrets}/runner-auth" "https://api.github.com/orgs/$(setting org)/actions/runner-groups?per_page=100" |
    jq -r --arg name "$(setting group)" '.runner_groups[] | select(.name == $name) | .id')"
  [[ -n "$group_id" ]] || { echo "Runner group $(setting group) does not exist." >&2; return 1; }

  imds="$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
  instance="$(curl -fsS -H "X-aws-ec2-metadata-token: ${imds}" http://169.254.169.254/latest/meta-data/instance-id)"
  request="$(jq -cn --arg name "${instance}-${index}-$(date +%s)" --argjson group "$group_id" \
    --argjson labels "$(jq -c .labels "$config")" \
    '{name: $name, runner_group_id: $group, labels: $labels, work_folder: "_work"}')"
  install -d -o "$user" -g "$user" -m 0700 "/run/honua-gate-runner/${index}"
  github "${secrets}/runner-auth" -X POST -d "$request" "https://api.github.com/orgs/$(setting org)/actions/runners/generate-jitconfig" |
    jq -r .encoded_jit_config | install -o "$user" -g "$user" -m 0400 /dev/stdin "/run/honua-gate-runner/${index}/jitconfig"
  github "${secrets}/runner-auth" -X DELETE https://api.github.com/installation/token > /dev/null || true
}

check_prerequisites() {
  # Unlike runuser/PAM, setpriv preserves the service's open-file limit.
  setpriv --reuid "$uid" --regid "$(id -g "$user")" --init-groups \
    env HOME="$home" /bin/bash -c '. /etc/honua-gate-runner-env; exec /usr/local/bin/honua-gate-runner-check'
}

end_previous_job
restore_pristine_home
block_instance_metadata
check_prerequisites
register_for_one_job
PREPARE

cat > /usr/local/bin/honua-gate-runner-run <<'RUN'
#!/bin/bash
# Starts runner $1 for the single job its just-in-time configuration registers.
set -euo pipefail
jit_file="/run/honua-gate-runner/$1/jitconfig"
ACTIONS_RUNNER_INPUT_JITCONFIG="$(< "$jit_file")"
export ACTIONS_RUNNER_INPUT_JITCONFIG
rm -f "$jit_file"
. /etc/honua-gate-runner-env
/usr/local/bin/honua-gate-runner-check
cd "${HOME}/runner"
exec ./run.sh
RUN

cat > /etc/honua-gate-runner-env <<'ENVIRONMENT'
# These paths are private, writable, and reset with the home after every job.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"
export DOTNET_INSTALL_DIR="${HOME}/.dotnet" DOTNET_ROOT="${HOME}/.dotnet"
export RUNNER_TOOL_CACHE="${HOME}/.cache/toolcache" AGENT_TOOLSDIRECTORY="${HOME}/.cache/toolcache"
export PATH="${HOME}/.venv/bin:${HOME}/.dotnet:${HOME}/.local/bin:${PATH}"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC DOTNET_CLI_TELEMETRY_OPTOUT=1
ENVIRONMENT
chmod 0644 /etc/honua-gate-runner-env

# Fail before advertising readiness when a replacement image lacks workflow prerequisites.
cat > /usr/local/bin/honua-gate-runner-check <<'CHECK'
#!/bin/bash
set -euo pipefail
for tool in gh jq python3 pwsh docker git zip unzip curl node npm tar gzip xz zstd timeout openssl; do
  command -v "$tool" > /dev/null
done
node -e 'if (Number(process.versions.node.split(".")[0]) < 24) process.exit(1)'
python3 -c 'import yaml; assert int(yaml.__version__.split(".")[0]) == 6'
python3 -m pip install --dry-run --no-index 'PyYAML>=6,<7'
pwsh -NoLogo -NoProfile -Command '$ErrorActionPreference="Stop"; if ($PSVersionTable.PSVersion.Major -lt 7) { exit 1 }'
for directory in "$DOTNET_INSTALL_DIR" "$RUNNER_TOOL_CACHE"; do
  [[ -d "$directory" && -w "$directory" ]]
done
[[ "$(locale charmap)" == UTF-8 ]]
[[ "$(date +%Z)" == UTC ]]
[[ "$(ulimit -n)" -ge 65536 ]]
docker buildx version
docker compose version
docker info --format '{{json .SecurityOptions}}' | jq -e 'index("name=rootless") != null' > /dev/null
CHECK
chmod 0755 /usr/local/bin/honua-gate-runner-check

cat > /usr/local/sbin/honua-gate-runner-heartbeat <<'HEARTBEAT'
#!/bin/bash
# Publishes this instance and its idle runner count for the PR Gate runner selection.
set -euo pipefail
config=/etc/honua-gate-runner.json
setting() { jq -r ".$1" "$config"; }
imds="$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
instance="$(curl -fsS -H "X-aws-ec2-metadata-token: ${imds}" http://169.254.169.254/latest/meta-data/instance-id)"
idle=0
for index in $(seq 1 "$(setting runner_count)"); do
  user="gate-runner-${index}"
  if pgrep -u "$user" -x Runner.Listener > /dev/null && ! pgrep -u "$user" -x Runner.Worker > /dev/null; then
    idle=$((idle + 1))
  fi
done
/snap/bin/aws ssm put-parameter --region "$(setting region)" --name "$(setting heartbeat_parameter)" \
  --type String --overwrite --value \
  "$(jq -cn --arg instance "$instance" --argjson at "$(date +%s)" --argjson idle "$idle" '{instance: $instance, at: $at, idle: $idle}')" > /dev/null
HEARTBEAT
chmod 0700 /usr/local/sbin/honua-gate-runner-prepare /usr/local/sbin/honua-gate-runner-heartbeat
chmod 0755 /usr/local/bin/honua-gate-runner-run

cat > /etc/systemd/system/honua-gate-runner@.service <<'SERVICE'
[Unit]
Description=Ephemeral PR Gate runner %i
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
User=gate-runner-%i
ExecStartPre=+/usr/local/sbin/honua-gate-runner-prepare %i
ExecStart=/usr/local/bin/honua-gate-runner-run %i
Restart=always
RestartSec=15
TimeoutStartSec=5min
KillMode=control-group
LimitNOFILE=65536:524288
NoNewPrivileges=yes
ProtectSystem=full
ProtectProc=invisible
InaccessiblePaths=-/home/ubuntu -/root

[Install]
WantedBy=multi-user.target
SERVICE

cat > /etc/systemd/system/honua-gate-runner-heartbeat.service <<'SERVICE'
[Unit]
Description=Publish PR Gate runner readiness

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/honua-gate-runner-heartbeat
SERVICE

cat > /etc/systemd/system/honua-gate-runner-heartbeat.timer <<'TIMER'
[Unit]
Description=Publish PR Gate runner readiness every thirty seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
TIMER

# Root-owned templates and a root-only parent prevent jobs from changing the next job's home.
install -d -m 0700 /var/lib/honua-gate-runner
for index in $(seq 1 "$(gate runner_count)"); do
  user="gate-runner-${index}"
  useradd --create-home --shell /bin/bash "$user"
  uid="$(id -u "$user")"
  chmod 0700 "/home/${user}"
  loginctl enable-linger "$user"
  for _ in $(seq 1 30); do
    [[ -S "/run/user/${uid}/bus" ]] && break
    sleep 1
  done
  runuser -u "$user" -- env "XDG_RUNTIME_DIR=/run/user/${uid}" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus" \
    dockerd-rootless-setuptool.sh install > /dev/null
  # Isolated pip installs avoid Ubuntu's externally-managed system Python (PEP 668).
  # The distro PyYAML satisfies okf-requirements.txt inside this disposable venv.
  runuser -u "$user" -- python3 -m venv --system-site-packages "/home/${user}/.venv"
  install -d -o "$user" -g "$user" -m 0700 "/home/${user}/.dotnet" "/home/${user}/.cache/toolcache"
  install -d -m 0700 "/var/lib/honua-gate-runner/home-${index}"
  rsync -a --exclude .local/share/docker "/home/${user}/" "/var/lib/honua-gate-runner/home-${index}/"
  chown -R root:root "/var/lib/honua-gate-runner/home-${index}"

  # The runner and its rootless Docker share the account's slice, so one ceiling covers both.
  install -d "/etc/systemd/system/user-${uid}.slice.d" "/etc/systemd/system/honua-gate-runner@${index}.service.d"
  printf '[Slice]\nCPUQuota=%s%%\nMemoryMax=%sG\n' "$(gate cpu_quota_percent)" "$(gate memory_max_gib)" \
    > "/etc/systemd/system/user-${uid}.slice.d/50-gate-runner.conf"
  printf '[Service]\nSlice=user-%s.slice\n' "$uid" > "/etc/systemd/system/honua-gate-runner@${index}.service.d/50-slice.conf"
done
systemctl daemon-reload
systemctl enable --now honua-gate-runner-heartbeat.timer
for index in $(seq 1 "$(gate runner_count)"); do
  systemctl enable --now --no-block "honua-gate-runner@${index}.service"
done
