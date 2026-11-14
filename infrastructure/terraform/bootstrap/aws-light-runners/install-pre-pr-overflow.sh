# Sourced after the shared gate bootstrap; index 16 never registers with GitHub.
overflow_user=gate-runner-16
overflow_home=/home/${overflow_user}
id -u "$overflow_user" > /dev/null 2>&1 || provision_account 16
overflow_uid="$(id -u "$overflow_user")"
install -d -m 0755 "/etc/systemd/system/user-${overflow_uid}.slice.d"
printf '[Slice]\nCPUQuota=400%%\nMemoryMax=8G\n' \
  > "/etc/systemd/system/user-${overflow_uid}.slice.d/50-pre-pr-overflow.conf"
systemctl daemon-reload
systemctl set-property "user-${overflow_uid}.slice" CPUQuota=400% MemoryMax=8G
# SSH sessions and the user's rootless daemon share the same resource slice.
install -d -o "$overflow_user" -g "$overflow_user" -m 0700 \
  "$overflow_home/.ssh" "$overflow_home/repos" "$overflow_home/wt"
rsync -a /home/ubuntu/.dotnet/ "$overflow_home/.dotnet/"
chown -R "$overflow_user:$overflow_user" "$overflow_home/.dotnet"
# Restore account isolation before SSH or its persistent user services start.
cat > /usr/local/sbin/honua-overflow-protect <<'PROTECT'
#!/bin/bash
set -euo pipefail
uid="$(id -u gate-runner-16)"
iptables -C OUTPUT -m owner --uid-owner "$uid" -d 169.254.169.254 -j REJECT 2>/dev/null ||
  iptables -I OUTPUT -m owner --uid-owner "$uid" -d 169.254.169.254 -j REJECT
ip6tables -C OUTPUT -m owner --uid-owner "$uid" -d fd00:ec2::254 -j REJECT 2>/dev/null ||
  ip6tables -I OUTPUT -m owner --uid-owner "$uid" -d fd00:ec2::254 -j REJECT
PROTECT
chmod 0700 /usr/local/sbin/honua-overflow-protect
cat > /etc/systemd/system/honua-overflow-protect.service <<'PROTECTION_UNIT'
[Unit]
Description=Restore pre-pr overflow account isolation
DefaultDependencies=no
After=local-fs.target
Before=ssh.service ssh.socket
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/honua-overflow-protect
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
PROTECTION_UNIT
for protected_unit in ssh.service ssh.socket "user@${overflow_uid}.service"; do
  install -d "/etc/systemd/system/${protected_unit}.d"
  printf '[Unit]\nRequires=honua-overflow-protect.service\nAfter=honua-overflow-protect.service\n' \
    > "/etc/systemd/system/${protected_unit}.d/50-overflow-protection.conf"
done
systemctl daemon-reload
systemctl enable --now honua-overflow-protect.service
jq -r '.pre_pr_overflow.ssh_public_key' "$gate_config" |
  sed 's/^/no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty /' \
  > "$overflow_home/.ssh/authorized_keys"
chown "$overflow_user:$overflow_user" "$overflow_home/.ssh/authorized_keys"
chmod 0600 "$overflow_home/.ssh/authorized_keys"

cat > /usr/local/bin/honua-overflow-shell <<'SHELL'
#!/bin/bash
set -euo pipefail
. /etc/honua-gate-runner-env
exec /bin/bash -c "${SSH_ORIGINAL_COMMAND:?SSH command required}"
SHELL
chmod 0755 /usr/local/bin/honua-overflow-shell
cat > /etc/ssh/sshd_config.d/60-honua-overflow.conf <<'SSHD'
Match User gate-runner-16
    ForceCommand /usr/local/bin/honua-overflow-shell
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitTTY no
    DisableForwarding yes
Match all
SSHD
/usr/sbin/sshd -t
systemctl reload ssh

chmod 0755 /usr/local/bin/honua-pre-pr-exec /usr/local/bin/honua-pre-pr-session
