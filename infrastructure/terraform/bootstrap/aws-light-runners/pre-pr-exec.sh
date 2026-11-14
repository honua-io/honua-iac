#!/bin/bash
set -euo pipefail
[[ "$(id -un)" == gate-runner-16 ]] || exit 2
. /etc/honua-gate-runner-env
exec 9>"$HOME/.honua-overflow.lock"
flock -n 9 || exit 75
[[ ! -e /run/honua-gate-runner-draining ]] || exit 75
free_kib="$(df -Pk "$HOME" | awk 'NR == 2 {print $4}')"
(( free_kib >= 20 * 1024 * 1024 )) || exit 75
export DOTNET_PROCESSOR_COUNT=4 HONUA_STAGE0_MAX_CPU_COUNT=4

# A disconnected session can leave containers behind in this account's private daemon.
clear_containers() {
  local containers
  containers="$(timeout 30 docker ps -aq)" || return 75
  if [[ -n "$containers" ]]; then
    timeout 60 docker rm -f $containers > /dev/null || return 75
  fi
}
finish_session() {
  local status="$?"
  trap - EXIT
  clear_containers || printf 'Overflow container cleanup failed; next execution will retry cleanup.\n' >&2
  exit "$status"
}
clear_containers || exit 75
trap finish_session EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$@"
