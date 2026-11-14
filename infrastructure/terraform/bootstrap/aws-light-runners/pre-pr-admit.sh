#!/bin/bash
set -euo pipefail
[[ ! -e /run/honua-gate-runner-draining ]] || exit 75
free_kib="$(df -Pk "$HOME" | awk 'NR == 2 {print $4}')"
(( free_kib >= 20 * 1024 * 1024 )) || exit 75
