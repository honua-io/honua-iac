#!/usr/bin/env python3
"""Capture and restore explicitly listed files, including original absence."""
import base64
import hashlib
import os
from pathlib import Path
import stat


def capture(path):
    path = Path(path)
    record = {'path': str(path), 'exists': path.exists() or path.is_symlink()}
    if not record['exists']:
        return record
    info = path.lstat()
    record.update(uid=info.st_uid, gid=info.st_gid, mode=stat.S_IMODE(info.st_mode))
    if stat.S_ISLNK(info.st_mode):
        record['link'] = os.readlink(path)
    elif stat.S_ISREG(info.st_mode):
        content = path.read_bytes()
        record.update(content=base64.b64encode(content).decode(), sha256=hashlib.sha256(content).hexdigest())
    else:
        raise ValueError('only individual regular files and symlinks supported')
    return record


def restore(record):
    path = Path(record['path'])
    if not record['exists']:
        path.unlink(missing_ok=True)
        return
    temporary = path.with_name(path.name + '.canary-restore')
    if temporary.exists() or temporary.is_symlink():
        raise FileExistsError(temporary)
    if 'link' in record:
        temporary.symlink_to(record['link'])
        os.lchown(temporary, record['uid'], record['gid'])
    else:
        content = base64.b64decode(record['content'], validate=True)
        if hashlib.sha256(content).hexdigest() != record['sha256']:
            raise ValueError('rollback content hash mismatch')
        with temporary.open('xb') as stream:
            os.fchmod(stream.fileno(), record['mode'])
            os.fchown(stream.fileno(), record['uid'], record['gid'])
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
    os.replace(temporary, path)
