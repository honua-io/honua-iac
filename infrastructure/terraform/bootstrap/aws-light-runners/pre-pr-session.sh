#!/bin/bash
set -euo pipefail
[[ "$(id -un)" == gate-runner-16 ]] || exit 2
exec 9>"$HOME/.honua-overflow-session.lock"
flock -n 9 || exit 75
[[ ! -e /run/honua-gate-runner-draining ]] || exit 75
free_kib="$(df -Pk "$HOME" | awk 'NR == 2 {print $4}')"
(( free_kib >= 20 * 1024 * 1024 )) || exit 75
printf 'HONUA_OVERFLOW_ADMITTED\n'
# The router holds stdin open until snapshot, sync, execution and copy-back finish.
cat > /dev/null
# If admission SSH disconnects first, preserve checkout ownership until any
# already-running executor (including its container cleanup) has released its lock.
exec 8>"$HOME/.honua-overflow.lock"
flock 8
