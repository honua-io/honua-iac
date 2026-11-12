#!/usr/bin/env python3
"""Account-specific drain. Operator-only; never stops or signals a runner."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import time


def command(*args):
    return subprocess.check_output(args, text=True, timeout=30).strip()


def drained(snapshot):
    return (snapshot['mask'] and snapshot['state'] in ('inactive', 'failed')
            and snapshot['main_pid'] == '0' and snapshot['job'] in ('', '0')
            and not snapshot['processes'] and not snapshot['registered']
            and not snapshot['registration_file'])


def account_processes(uid, subordinate):
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            status = (entry / 'status').read_text()
        except FileNotFoundError:
            continue
        identities = next(line for line in status.splitlines() if line.startswith('Uid:'))
        values = list(map(int, identities.split()[1:]))
        if any(value == uid or subordinate[0] <= value < sum(subordinate) for value in values):
            found.append(int(entry.name))
    return found


class Host:
    def __init__(self, index, instance_id):
        self.index = index
        self.unit = f'honua-gate-runner@{index}.service'
        self.user = f'gate-runner-{index}'
        self.uid = pwd.getpwnam(self.user).pw_uid
        config = json.loads(Path('/etc/honua-gate-runner.json').read_text())
        self.org = config['org']
        self.prefix = instance_id + f'-{index}-'
        if not re.fullmatch(r'i-[0-9a-f]{8,17}', instance_id):
            raise ValueError('operator must pin audited instance ID')
        entries = [line.split(':') for line in Path('/etc/subuid').read_text().splitlines()]
        ranges = [(int(start), int(count)) for name, start, count in entries if name == self.user]
        if len(ranges) != 1 or ranges[0][1] <= 0:
            raise ValueError('one subordinate UID range required')
        self.subordinate = ranges[0]

    def exclude(self):
        command('systemctl', 'mask', '--runtime', self.unit)
        command('systemctl', 'daemon-reload')

    def snapshot(self):
        properties = command('systemctl', 'show', self.unit,
                             '-p', 'ActiveState', '-p', 'MainPID', '-p', 'Job', '-p', 'LoadState')
        state = dict(line.split('=', 1) for line in properties.splitlines())
        groups = json.loads(command('gh', 'api', '--paginate', '--slurp',
                                    f'/orgs/{self.org}/actions/runners?per_page=100'))
        registered = [r['id'] for page in groups for r in page['runners']
                      if r['name'].startswith(self.prefix)]
        mask = Path('/run/systemd/system') / self.unit
        return {'mask': mask.is_symlink() and os.readlink(mask) == '/dev/null'
                        and state['LoadState'] == 'masked',
                'state': state['ActiveState'], 'main_pid': state['MainPID'], 'job': state['Job'],
                'processes': account_processes(self.uid, self.subordinate),
                'registered': registered,
                'registration_file': Path(f'/run/honua-gate-runner-state/{self.index}').exists()}


def drain(host, deadline):
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    host.exclude()
    while time.monotonic() < deadline:
        snapshot = host.snapshot()
        if Path('/proc/sys/kernel/random/boot_id').read_text().strip() != boot:
            raise RuntimeError('reboot invalidated runtime exclusion')
        if drained(snapshot):
            return {'boot_id': boot, 'observed_at': time.time(), 'snapshot': snapshot}
        time.sleep(5)
    raise TimeoutError('natural single-job drain incomplete; KEEP MASK; no stop or kill authorized')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--index', type=int, required=True, choices=range(1, 11))
    parser.add_argument('--instance-id', required=True)
    parser.add_argument('--timeout', type=int, default=1800)
    options = parser.parse_args()
    if os.geteuid() != 0 or not 1 <= options.timeout <= 7200:
        raise ValueError('root and bounded timeout required')
    directory = Path('/var/lib/honua-rootless-canary')
    directory.mkdir(mode=0o700, exist_ok=True)
    lock = directory / f'{options.index}.lock'
    with lock.open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = drain(Host(options.index, options.instance_id), time.monotonic() + options.timeout)
        print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
