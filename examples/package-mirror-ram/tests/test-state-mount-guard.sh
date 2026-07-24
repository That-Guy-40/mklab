#!/usr/bin/env bash
# test-state-mount-guard.sh — prove state-mount.sh is properly ||-GUARDED: a
# failing network-storage mount must NEVER abort (it would panic PID 1 under
# /init's `set -e`), and a working mount must actually be attempted.
#
# Host-only: no docker, no root, no real NFS/iSCSI — `mount`/`mountpoint`/
# `iscsiadm` are stubbed on PATH. (The live NFS/iSCSI round-trip is author-run —
# see MANUAL_TESTING.md — because it touches host-global kernel state.)
#
# One verdict (house rule). PASS requires ALL:
#   1. NFS mount FAILS  → exit 0 + WARN  (the regression guard: no panic)
#   2. NFS mount OK      → exit 0 + a real `mount -t nfs4 …` was attempted
#   3. iSCSI attach FAILS→ exit 0 (guard)
#   4. already-mounted   → exit 0, no re-mount
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../state-mount.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/state-mount-test.XXXXXX")"
BIN="$TMP/bin"; mkdir -p "$BIN"

skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

trap 'rc=$?; rm -rf -- "$TMP"; [[ $rc == 0 || $rc == 77 || $rc == 1 ]] || \
      printf "FAIL: test exited early (rc=%s)\n" "$rc" >&2' EXIT

[[ -f "$SUT" ]] || fail "missing script under test: $SUT"

# Stub factory: write a fake command that logs its call and returns $rc.
make_stub() { # <name> <rc>
    cat > "$BIN/$1" <<EOF
#!/bin/sh
echo "\$(basename "\$0") \$*" >> "$TMP/calls.log"
exit $2
EOF
    chmod +x "$BIN/$1"
}

run_sut() { # env assignments... ; resets call log; returns SUT exit code
    : > "$TMP/calls.log"
    env PATH="$BIN:$PATH" MIRROR_MNT="$TMP/mnt" "$@" sh "$SUT" >"$TMP/out" 2>&1
}

# mountpoint defaults to "not mounted" (rc 1) unless a scenario overrides it.
make_stub mountpoint 1

# ── 1. NFS mount FAILS → must still exit 0 (the guard) ──────────────────────
make_stub mount 1
if run_sut STATE_KIND=nfs STATE_SRC=10.0.0.9:/export; then :; else
    fail "REGRESSION: state-mount.sh exited NON-ZERO when the NFS mount failed — /init would panic PID 1"
fi
grep -q "WARN: NFS mount" "$TMP/out" || fail "failed NFS mount did not log the WARN"
note "NFS mount failure → exit 0 + WARN (guard holds)"

# ── 2. NFS mount OK → exit 0 AND a real nfs4 mount was attempted ─────────────
make_stub mount 0
run_sut STATE_KIND=nfs STATE_SRC=10.0.0.9:/export || fail "exit non-zero on a SUCCESSFUL nfs mount"
grep -q "mount -t nfs4" "$TMP/calls.log" || fail "did not attempt 'mount -t nfs4 …' for STATE_KIND=nfs"
grep -q "10.0.0.9:/export" "$TMP/calls.log" || fail "nfs mount did not use STATE_SRC"
note "NFS mount success → exit 0 + real nfs4 mount attempted"

# ── 3. iSCSI attach FAILS → must still exit 0 (the guard) ───────────────────
make_stub iscsiadm 1
make_stub mount 0
run_sut STATE_KIND=iscsi ISCSI_PORTAL=10.0.0.9:3260 ISCSI_TARGET=iqn.2026-07.lab:mirror \
    || fail "REGRESSION: iSCSI attach failure aborted state-mount.sh (would panic /init)"
grep -q "WARN: iSCSI" "$TMP/out" || fail "failed iSCSI attach did not log the WARN"
note "iSCSI attach failure → exit 0 + WARN (guard holds)"

# ── 4. already mounted → exit 0, no re-mount ────────────────────────────────
make_stub mountpoint 0     # pretend the mount point is already a mount
make_stub mount 1          # if it (wrongly) tried to mount, this would fail
run_sut STATE_KIND=nfs STATE_SRC=10.0.0.9:/export \
    || fail "exited non-zero when the mirror was already mounted"
grep -q "mount -t" "$TMP/calls.log" && fail "re-mounted an already-mounted mirror (should skip)"
note "already-mounted → exit 0, no re-mount"

pass "state-mount.sh: network-storage mount is ||-guarded (failures never panic /init), success mounts, idempotent"
