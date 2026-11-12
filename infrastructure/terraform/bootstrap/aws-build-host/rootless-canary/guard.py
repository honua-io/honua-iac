#!/usr/bin/env python3
"""Fail closed before child startup mutations and before allocator writes."""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def protected_file(path):
    target = Path(path)
    if not target.is_absolute():
        raise ValueError('absolute protected path required')
    mapping = Path('/proc/self/uid_map').read_text().splitlines()
    host_root_mapped = any(int(line.split()[1]) == 0 for line in mapping)
    owner = 0 if host_root_mapped else int(Path('/proc/sys/kernel/overflowuid').read_text())
    for component in (target, *target.parents):
        info = component.lstat()
        if info.st_uid != owner or info.st_mode & 0o022 or stat.S_ISLNK(info.st_mode):
            raise ValueError('root-owned non-writable path required: ' + str(component))
    if not stat.S_ISREG(target.lstat().st_mode):
        raise ValueError('regular file required')
    return target


def read_config(path):
    target = protected_file(path)
    config = json.loads(target.read_text())
    index = config['index']
    if type(index) is not int or not 1 <= index <= 10:
        raise ValueError('invalid account index')
    if str(target) != f'/opt/honua-rootless-canary/{index}.json':
        raise ValueError('fixed account configuration path required')
    if type(config['uid']) is not int or config['uid'] < 1001:
        raise ValueError('invalid account UID')
    return config


def check_namespace(config, evidence):
    if evidence['child'] != '1' or evidence['uid_map'][0] != [0, config['uid'], 1]:
        raise ValueError('wrong rootless child or UID mapping')
    for name in ('net', 'user', 'mnt'):
        host = config['host_namespaces'][name]
        if type(host) is not int or host <= 0 or evidence['namespaces'][name] == host:
            raise ValueError('private namespace required: ' + name)
    if evidence['boot_id'] != config['boot_id']:
        raise ValueError('host reboot invalidated canary evidence')


def evidence():
    return {
        'child': os.environ.get('_DOCKERD_ROOTLESS_CHILD'),
        'uid_map': [list(map(int, line.split())) for line in Path('/proc/self/uid_map').read_text().splitlines()],
        'namespaces': {name: os.stat('/proc/self/ns/' + name).st_ino for name in ('net', 'user', 'mnt')},
        'boot_id': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
    }


def verify_binary(config):
    binary = Path(config['dockerd'])
    if str(binary) != '/usr/bin/dockerd':
        raise ValueError('only packaged dockerd path supported')
    binary = protected_file(binary)
    if hashlib.sha256(binary.read_bytes()).hexdigest() != config['dockerd_sha256']:
        raise ValueError('dockerd hash changed')
    return str(binary)


def allocate(config):
    check_namespace(config, evidence())
    first = 20000 + 1000 * (config['index'] - 1)
    target = Path('/proc/sys/net/ipv4/ip_local_port_range')
    target.write_text(f'{first} {first + 999}\n')
    check_namespace(config, evidence())
    if list(map(int, target.read_text().split())) != [first, first + 999]:
        raise ValueError('allocator range readback mismatch')


def main():
    config = read_config(os.environ['HONUA_ROOTLESS_CANARY_CONFIG'])
    check_namespace(config, evidence())
    if sys.argv[1:] and sys.argv[1] == 'dockerd':
        binary = verify_binary(config)
        allocate(config)
        os.execv(binary, [binary, *sys.argv[2:]])


if __name__ == '__main__':
    main()
