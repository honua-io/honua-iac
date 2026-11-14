#!/bin/bash
set -euo pipefail
[[ "$(id -un)" == gate-runner-16 ]] || exit 2
exec 9>"$HOME/.honua-overflow-session.lock"
flock -n 9 || exit 75
/usr/local/bin/honua-pre-pr-admit
printf 'HONUA_OVERFLOW_ADMITTED\n'
# The router holds stdin open until snapshot, sync, execution and copy-back finish.
cat > /dev/null
# If admission SSH disconnects first, preserve checkout ownership until any
# already-running executor (including its container cleanup) has released its lock.
exec 8>"$HOME/.honua-overflow.lock"
flock 8
