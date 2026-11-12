#!/usr/bin/env python3
"""Generate a separate startup copy; never replace the packaged startup file."""
import hashlib
from pathlib import Path
import sys

UPSTREAM_SHA256 = '200203633806081a401e60aefdf68a8fa73fc7dc80aa854c52a69d47710a3488'
GUARD = '/opt/honua-rootless-canary/guard.py'


def render(raw):
    if hashlib.sha256(raw).hexdigest() != UPSTREAM_SHA256:
        raise ValueError('unexpected pinned startup source')
    source = raw.decode()
    prefix = '''
: "${HONUA_ROOTLESS_CANARY_CONFIG:?root-owned canary configuration required}"
[ -z "${DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS:-}" ] || exit 1
case "${_DOCKERD_ROOTLESS_CHILD:-}:${DOCKERD:-}" in
  :|1:/opt/honua-rootless-canary/dockerd-wrapper) ;;
  *) exit 1 ;;
esac
export DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=false
export DOCKERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns
export DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=builtin
export DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=true
export DOCKERD_ROOTLESS_ROOTLESSKIT_MTU=65520
export DOCKERD_ROOTLESS_ROOTLESSKIT_SLIRP4NETNS_SANDBOX=auto
export DOCKERD_ROOTLESS_ROOTLESSKIT_SLIRP4NETNS_SECCOMP=auto
export DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS=
export DOCKERD=/opt/honua-rootless-canary/dockerd-wrapper
'''
    source = source.replace('set -e -x\n', 'set -e\n' + prefix, 1)
    marker = '\t[ "$_DOCKERD_ROOTLESS_CHILD" = 1 ]\n'
    source = source.replace(marker, marker + f'\tpython3 {GUARD}\n', 1)
    source = source.replace('\tnsenter -n"$netns" sysctl', f'\tpython3 {GUARD}\n\tnsenter -n"$netns" sysctl')
    return source


if __name__ == '__main__':
    upstream = Path(__file__).with_name('dockerd-rootless.upstream.sh')
    destination = Path(sys.argv[1])
    with destination.open('x') as stream:
        stream.write(render(upstream.read_bytes()))
