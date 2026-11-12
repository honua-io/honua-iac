# Offline, account-specific rootless isolation canary

These files are preparation only. Terraform and bootstrap do not install or
execute them. MAIN must check reviewed source, exclusion proof and rollback
before any live mask, service, namespace, sysctl or container action. No change
to rootful Redis, jobsncache ownership, ten gate accounts or job admission caps.

## Source and scope

`dockerd-rootless.upstream.sh` is the unmodified Moby startup script at
70efc0e (the deployed Docker 29.9.3 source), SHA-256
200203633806081a401e60aefdf68a8fa73fc7dc80aa854c52a69d47710a3488.
`prepare.py OUTPUT` verifies the pin and creates a separate startup copy; it
never overwrites the package. Run it offline. Install only reviewed bytes under
root-owned, non-writable `/opt/honua-rootless-canary`, executable scripts 0755.
The packaged `/usr/bin/dockerd` stays unchanged; record its actual deployed
SHA-256 and verify version before configuring a canary. Unsupported paths fail.

The generated script forces slirp4netns/builtin, disables host loopback and
**disables detached netns**. Arbitrary RootlessKit flags and an unexpected
DOCKERD override fail before startup. Child guards precede upstream filesystem
mutation and each forwarding sysctl. The dockerd wrapper repeats the guard,
sets and reads back a private allocator range, then execs the hash-pinned
packaged binary. Account N uses 20000+1000*(N-1) through 20999+1000*(N-1).
All ten ranges are disjoint and below the observed host default 32768–60999.
Audit host listeners and reserved ports against the selected range first;
range availability and host defaults are activation prerequisites, not assumed
from the formula. No host sysctl is changed by this design.

Per-account `/opt/honua-rootless-canary/N.json` must be a root-owned 0644 regular
file, with every ancestor root-owned and non-writable. It contains `index`,
`uid` (actual account UID), `boot_id` (current host boot), `host_namespaces`
(net/user/mnt inode numbers observed from host context), `dockerd` (exactly
`/usr/bin/dockerd`) and `dockerd_sha256`. Rootless child UID mapping must start
with `0 ACTUAL_UID 1`; all three namespaces must differ from the captured host.
A reboot invalidates the configuration. Host root ownership appears as overflow
UID inside the child user namespace; protected paths outside RootlessKit's
`/etc` and `/run` copy-up trees retain host protection. This is an operational
fail-closed guard for this pinned startup, not a sandbox against malicious code
already running as the account. Run parent-context ownership/hash inspection
before installation; child inspection is not a substitute for it.

## Admission barrier and natural drain

After MAIN clearance, root may invoke `admission.py --index N --instance-id
AUDITED_INSTANCE_ID --timeout 1800`. Use a GitHub credential with authoritative
organization runner-list read access; the script does not fetch or print tokens.
The supplied instance ID must match the host and runner naming scheme observed
by MAIN. The configured organization comes from `/etc/honua-gate-runner.json`.
The program serializes its own per-account operators and runtime-masks only
`honua-gate-runner@N.service`, **without --now**, then reloads systemd.
It never stops/signals jobs, services or containers and never deletes GitHub
registrations. An assignment racing the mask is allowed to finish naturally.

Exclusion proof requires the mask symlink and systemd masked state, inactive or
failed unit, MainPID zero, no pending systemd job, no account or subordinate-UID
processes, no matching registrations on **all** organization runner-list pages,
and no local registration-state file. Existing ExecStopPost removes registration
and cleans the job; the barrier prevents another start. Merely seeing `busy:
false`, a quiet CPU, or an empty Docker list is insufficient. Any read/auth/API
failure aborts. An idle listener can remain alive indefinitely: timeout retains
the mask and reports failure; no automatic kill or unmask follows.

Runtime masks disappear on reboot and root can remove them. MAIN must maintain
exclusive control of this account, prevent a competing provisioner/unmask, and
repeat the entire proof immediately before every installation/activation or
rollback step. Do not treat saved JSON as a lease. An isolated systemd rehearsal
must demonstrate pending-start/running-job/restart behavior before live use;
fake-host tests validate logic but do not prove that host integration. The
current preparation is therefore **not live activation approval**.

## Rollback manifest and activation conditions

Before writing anything, with the barrier proven, store a root-only 0600 JSON
manifest outside runner homes under `/var/lib/honua-rootless-canary/N/`.
`manifest.capture(path)` records regular-file bytes/hash, mode, owner, symlink
or explicit original absence; `manifest.restore(record)` restores that state
atomically and rejects corrupt backups. Capture each file individually; it
intentionally refuses directories and never recursively deletes anything.

Enumerate every proposed path, including the generated startup, guard, wrapper,
config, account live-home and pristine-home Docker user-unit override files.
Record parent-directory preexistence separately; remove newly created parents
only if empty. Save boot ID, source hashes, package versions, host namespace
inodes, system and user unit states, existing mask state, user-manager environment
and relevant unit/drop-in contents. Manager environment may contain secrets:
keep it root-only and do not put it in source, PRs or shared logs. Do not mutate
manager environment for this canary; use an account-specific Docker service
Environment/ExecStart override. Preserve original ExecStart arguments, reset it
before replacement and point it to the separately generated script; set the
account config path with Environment. Never edit a shared user-unit drop-in.
Both live and root-owned pristine-home copies need the override because normal
prepare restores the home before starting Docker. Capture both original states.

MAIN must approve the exact installation manifest and command sequence. Once
idle/excluded, start only the selected account's user manager/Docker for a
manual canary while the gate unit remains masked; do not register a listener.
Verify daemon/container/user/netns identity and private allocator range from
actual runner context. Require Ryuk, PostGIS, IPv4/IPv6 published-port, pull and
build checks, then a two-account parallel port test before expansion. Capture
compatibility and performance against detached-netns baseline; slower network
traffic is a known possibility. A private daemon namespace alone does not prove
Testcontainers can reach published ports from the runner context.

For rollback, retain the gate mask, stop only a proven idle canary after MAIN
clearance, restore all manifest entries (including absence) in both homes,
restore recorded manager/unit state and verify byte hashes/owners/modes. If
anything is busy or identity differs, stop the procedure without signaling it.
Do not unmask until MAIN explicitly releases admission after fresh proof. Do not
restore a preexisting persistent mask as an unmasked unit. Reboot or loss of
barrier invalidates the procedure and requires re-evaluation.

## Alternative considered

GitHub runner APIs expose registration listing/deletion but no atomic
"exclude future assignments and drain this active runner" primitive available
here. Deleting a live registration is unsafe. The local mask plus natural
single-job completion removes future activations without that API, provided
systemd rehearsal and exclusive operator control hold. If an idle listener
cannot naturally drain, report the exact missing shutdown primitive to MAIN.

A smaller Moby change could override the allocator's dynamic range per daemon
in `libnetwork/portallocator/portallocator.go` rather than change namespaces.
The pinned source reads the kernel range once during allocator construction;
a validated explicit override could avoid both shared-port selection and
network performance changes. It would require maintaining a custom, fully
hash-pinned Docker binary, rejecting malformed/overlapping ranges without
falling back silently, and allocator/race/integration coverage. That introduces
a package supply/maintenance path absent from this preparation. No custom
binary build or deployment is authorized here. Prefer it for MAIN evaluation
if the admission/integration prerequisites above cannot be met safely.

## Focused offline checks

Run via the existing build-host shim and durable lane-driver:
`remote-run python3 -m unittest discover -s
infrastructure/terraform/bootstrap/aws-build-host/rootless-canary -p test_canary.py -v`.
Tests use temporary files/mocked host operations; no host service or namespace
changes occur. Independent exact-head review remains required separately.

The generated startup constrains RootlessKit state to `/run/user/<numeric UID>/dockerd-rootless`
and quotes the state-directory argument. The admission query pins `github.com` even
when an operator shell exports a conflicting `GH_HOST`. Both have regression tests.
