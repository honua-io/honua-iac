#!/usr/bin/env python3
"""Stop an idle lane host without treating low CPU as inactivity."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pwd
import subprocess
import time

CONFIG = Path("/etc/honua-lane-host.json")
STATE = Path("/run/honua-lane-last-active")
LOCK = Path("/run/lock/honua-lane-activity.lock")
STOPPING = Path("/run/honua-lane-stopping")
PASSIVE = {"systemd", "(sd-pam)", "dbus-daemon", "gpg-agent", "VBCSCompiler"}


def processes(uid):
    rows = {}
    for directory in Path("/proc").iterdir():
        if not directory.name.isdigit():
            continue
        try:
            if directory.stat().st_uid != uid:
                continue
            stat = (directory / "stat").read_text().rsplit(")", 1)[1].split()
            argv = (directory / "cmdline").read_bytes().decode(errors="replace").rstrip("\0").split("\0")
            if stat[0] == "Z":
                continue
            rows[int(directory.name)] = {"parent": int(stat[1]), "start": stat[19],
                                         "comm": (directory / "comm").read_text().strip(), "argv": argv}
        except (FileNotFoundError, ProcessLookupError):
            continue
    return rows


def busy_processes(rows, config):
    ignored = set()
    pinned = config.get("passive_processes", {})
    commands = config.get("passive_commands", [])
    for pid, row in rows.items():
        if row["comm"] in PASSIVE or pinned.get(str(pid)) == row["start"]:
            ignored.add(pid)
        elif row["argv"] in commands:
            ignored.add(pid)
    # Ignore only direct timer sleeps, never whole daemon subtrees.
    sleeping = {pid for pid, row in rows.items()
                if row["comm"] == "sleep" and row["parent"] in ignored}
    return sorted(set(rows) - ignored - sleeping - {os.getpid()})


def load_config():
    config = json.loads(CONFIG.read_text())
    # The persistent file is mandatory: replacement hosts must retain queue guards.
    activity_config = json.loads(Path(config["activity_config"]).read_text())
    if not isinstance(activity_config.get("work_probe"), list) or not activity_config["work_probe"]:
        raise ValueError("a pending-work probe is required")
    for key in ("work_probe", "passive_commands", "passive_processes", "user"):
        if key in activity_config:
            config[key] = activity_config[key]
    return config


def activity(config):
    probe = config.get("work_probe", [])
    if probe:
        result = subprocess.run(["runuser", "-u", config.get("user", "ubuntu"), "--", *probe],
                                capture_output=True, timeout=20)
        if result.returncode != 0:
            return "pending work or work probe failed"
    uid = pwd.getpwnam(config.get("user", "ubuntu")).pw_uid
    busy = busy_processes(processes(uid), config)
    return "active process IDs: " + ",".join(map(str, busy[:12])) if busy else ""


def idle_elapsed(now, state):
    try:
        previous = float(state.read_text())
        return max(0, now - previous) if 0 <= previous <= now else 0
    except (OSError, ValueError):
        return 0


def evaluate(config, check_only):
    seconds = config.get("idle_seconds", 1800)
    if not isinstance(seconds, (int, float)) or not 600 <= seconds <= 86400:
        raise ValueError("idle_seconds must be between 600 and 86400")
    with LOCK.open("a+") as admission:
        try:
            fcntl.flock(admission, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            report("lane admission lock held", check_only)
            return
        reason = activity(config)
        now = time.monotonic()
        if reason or not STATE.exists():
            report(reason or "starting idle window", check_only)
            return
        elapsed = idle_elapsed(now, STATE)
        print(json.dumps({"idle_seconds": int(elapsed), "threshold": seconds,
                          "would_stop": elapsed >= seconds, "check_only": check_only}), flush=True)
        if elapsed >= seconds and not check_only:
            # Recheck while holding admission closed through the shutdown request.
            reason = activity(config)
            if reason:
                report(reason, False)
                return
            STOPPING.touch()
            try:
                subprocess.run(["systemctl", "poweroff"], check=True, timeout=30)
            except Exception:
                STOPPING.unlink(missing_ok=True)
                raise


def report(reason, check_only):
    if not check_only:
        STATE.write_text(str(time.monotonic()))
    print(json.dumps({"busy": reason, "check_only": check_only}), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="inspect without changing state or stopping")
    args = parser.parse_args()
    try:
        evaluate(load_config(), args.check)
    except Exception as error:
        report("inspection failed: " + type(error).__name__, args.check)
        raise


if __name__ == "__main__":
    main()
