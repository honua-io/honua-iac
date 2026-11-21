# Nightly benchmark quiet window (founder, 21 Nov 2026): 12:00-13:15 UTC the gate and heavy
# runners take no jobs, so benchmarks measure the code and not the CI load. Pools other than
# gate and heavy are left alone. Installed after the runner services; rerunning converges.
cat > /usr/local/sbin/honua-quiet-window <<'QUIET'
#!/bin/bash
# honua-quiet-window drain|resume. drain: no runner restarts after its job; an idle runner is
# deregistered first (GitHub refuses a runner holding a job) and only then stopped, so no job is
# killed; a busy one is waited for up to 20 minutes. resume: start them all.
set -uo pipefail
config=/etc/honua-gate-runner.json
status=/run/honua-quiet-window
hold=/run/honua-quiet-window.hold
start="${HONUA_QUIET_START:-12:00}" end="${HONUA_QUIET_END:-13:15}"
wait_seconds="${HONUA_QUIET_WAIT_SECONDS:-1200}" poll="${HONUA_QUIET_POLL_SECONDS:-10}"
indices=($(jq -r '.runners | to_entries[] | select(.value.pool == "gate" or .value.pool == "heavy") | .key + 1' "$config"))
busy() { pgrep -u "gate-runner-$1" -x Runner.Worker > /dev/null; }
deregistered() { /usr/local/sbin/honua-gate-runner-registration remove "$1" > /dev/null 2>&1; }
report() {
  local stopped=0 index
  for index in "${indices[@]}"; do
    systemctl is-active --quiet "honua-gate-runner@${index}.service" || stopped=$((stopped + 1))
  done
  printf '%s drained=%d/%d load=%s at=%s\n' "$1" "$stopped" "${#indices[@]}" \
    "$(cut -d' ' -f1 /proc/loadavg)" "$(date -u +%FT%TZ)" > "$status.tmp" && mv -f "$status.tmp" "$status"
}
case "${1:-}" in
  drain)
    now="$(date -u +%s)" opens="$(date -u -d "today $start" +%s)" closes="$(date -u -d "today $end" +%s)"
    # The boot run drains only inside the window; the calendar run always drains.
    if [[ "${2:-}" == --if-open ]] && (( now < opens || now >= closes )); then exit 0; fi
    (( closes > now )) || closes=$((now + 75 * 60))
    touch "$hold"
    pending=("${indices[@]}")
    deadline=$((SECONDS + wait_seconds))
    while :; do
      # Resume, or the end of the window, ends the drain; it must not stop restarted runners.
      [[ -e "$hold" ]] && (( $(date -u +%s) < closes )) || break
      left=()
      for index in "${pending[@]}"; do
        if ! busy "$index" && deregistered "$index"; then
          systemctl stop "honua-gate-runner@${index}.service"
        else
          left+=("$index")
        fi
      done
      pending=("${left[@]}")
      report "open until=$closes busy=${#pending[@]}"
      (( ${#pending[@]} > 0 && SECONDS < deadline )) || break
      sleep "$poll"
    done
    # A runner still busy at the deadline keeps its job; the hold stops it restarting afterwards.
    exit 0 ;;
  resume)
    rm -f "$hold"
    for index in "${indices[@]}"; do systemctl start --no-block "honua-gate-runner@${index}.service"; done
    report closed
    exit 0 ;;
  *) echo "usage: honua-quiet-window drain [--if-open] | resume" >&2; exit 2 ;;
esac
QUIET
chmod 0700 /usr/local/sbin/honua-quiet-window

mkdir -p /etc/systemd/system/honua-gate-runner@.service.d
cat > /etc/systemd/system/honua-gate-runner@.service.d/quiet-window.conf <<'DROPIN'
[Unit]
ConditionPathExists=!/run/honua-quiet-window.hold
DROPIN

for phase in drain resume; do
  if [[ "$phase" == drain ]]; then when='12:00:00'; args='drain'; else when='13:15:00'; args='resume'; fi
  cat > "/etc/systemd/system/honua-quiet-window-${phase}.service" <<SERVICE
[Unit]
Description=Benchmark quiet window: ${phase} the gate and heavy runners

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/honua-quiet-window ${args}
TimeoutStartSec=30min
SERVICE
  if [[ "$phase" == resume ]]; then
    sed -i '/^Description=/a Conflicts=honua-quiet-window-drain.service honua-quiet-window-boot.service\nAfter=honua-quiet-window-drain.service honua-quiet-window-boot.service' \
      "/etc/systemd/system/honua-quiet-window-${phase}.service"
  fi
  cat > "/etc/systemd/system/honua-quiet-window-${phase}.timer" <<TIMER
[Unit]
Description=Benchmark quiet window ${phase} at ${when} UTC

[Timer]
OnCalendar=*-*-* ${when} UTC
AccuracySec=1s

[Install]
WantedBy=timers.target
TIMER
done
# A host launched inside the window drains once its runners have started. Every launch is a
# first boot, during which cloud-init runs this, so the unit also starts now.
cat > /etc/systemd/system/honua-quiet-window-boot.service <<'SERVICE'
[Unit]
Description=Benchmark quiet window: drain at boot inside the window
After=multi-user.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 60
ExecStart=/usr/local/sbin/honua-quiet-window drain --if-open
TimeoutStartSec=30min

[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl enable --now honua-quiet-window-drain.timer honua-quiet-window-resume.timer
systemctl enable --now --no-block honua-quiet-window-boot.service
