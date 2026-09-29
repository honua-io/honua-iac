#!/usr/bin/env bash
# Shared fail-closed contract for N-1 -> N -> N-1 certification images.
require_digest_image() {
  local name="$1" image="$2"
  if [[ ! "$image" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]+)?(/[A-Za-z0-9._-]+)+@sha256:[0-9a-f]{64}$ ]]; then
    echo "$name must be registry/repository@sha256:<64 lowercase hex>; mutable tags are refused" >&2
    return 1
  fi
}
require_revision_pair() {
  require_digest_image PREVIOUS_IMAGE "$1" || return 1
  require_digest_image IMAGE "$2" || return 1
  if [[ "${1##*@}" == "${2##*@}" ]]; then
    echo "Upgrade/rollback requires two different image digests" >&2
    return 1
  fi
}
