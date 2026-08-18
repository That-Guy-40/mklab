#!/usr/bin/env bash
# A REAL Firecracker snapshot, restored, and the proof that the guest RESUMED.
#
# The sibling `test-snapshot-refusals.sh` covers every gate with a stand-in VMM and runs
# anywhere. This one needs a real Firecracker, real KVM and a real bootable guest, because
# the property under test is not "the tool issues the right API calls" — it is *did the
# machine come back as the same machine* — and no stand-in can answer that.
#
# ── HOW "THE SAME MACHINE" IS MEASURED, AND WHY IT IS NOT A FILE ────────────────────────
# The guest prints a MONOTONIC COUNTER to its console, once a second, from a loop started
# at boot. That gives three distinguishable outcomes from one signal:
#
#     restored          → the counter continues from the captured value  (what we assert)
#     rebooted          → the counter restarts at 1, with a kernel banner above it
#     never came up     → no counter at all
#
# A marker FILE could not tell the first two apart: the rootfs is copied into the snapshot,
# so a rebooted guest would find the same file and "pass". Memory continuity is the only
# thing that distinguishes a restore from a fresh boot, so the assertion is made of memory.
#
# The counter is started by BACKGROUNDING it from a `sysinit` action. busybox init runs
# every `sysinit` entry to completion before it starts any `respawn` one, so a ticker
# registered as `respawn` would not exist for the guest's first ~40 s (measured in slice 5c).
#
# ── THE CONSOLE LOG IS APPEND-ONLY ACROSS RESTORES, SO IT IS READ FROM A MARK ───────────
# `snapshot restore` appends to the same fc.log. Reading the whole file after a restore
# would find the pre-snapshot ticks and "prove" continuity that had not happened — this
# repo has already shipped that bug once, in metal-as-a-service, where an append-only
# console from a previous deploy made a second deploy report `active` in one second. So the
# byte offset is recorded BEFORE the restore and only what comes after it is read.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd curl sha256sum e2fsck debugfs

W="${MC_WORKDIR:-$HOME/.local/state/lab-create/micro-cloud-s3}"
KERNEL="${MC_KERNEL:-$W/vmlinux}"
BASE="${MC_ROOTFS:-$W/api1.ext4}"

# The VMM is looked for WHERE THIS REPO PUTS IT, not only on PATH. `lab-fc.sh` invokes
# `firecracker` by name, and slice 1 fetched the pinned binary into the micro-cloud workdir
# rather than installing it system-wide — so requiring it on PATH made this test SKIP on the
# one machine that can actually run it, which is the shape of a guard that quietly retires
# the question it was meant to ask. The sibling micro-cloud tests resolve it the same way.
if ! command -v firecracker >/dev/null 2>&1; then
    [[ -x "$W/firecracker" ]] \
        || skip "no firecracker on PATH and none at $W/firecracker — nothing to snapshot"
    PATH="$W:$PATH"; export PATH
fi

[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] \
    || skip "/dev/kvm is not read-write for uid $EUID — a snapshot captures a running guest, and there is none without KVM"
[[ -r "$KERNEL" ]] || skip "no bootable kernel at $KERNEL (slice 1/3 artifacts absent) — nothing to boot"
[[ -r "$BASE"   ]] || skip "no bootable rootfs at $BASE (slice 1/3 artifacts absent) — nothing to boot"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")
export LAB_STATE_DIR="$tmp/state"
NAME="snaprt"
# Teardown registered BEFORE anything is created, so it runs however this ends. By NAME
# through the tool's own verb — never a pattern: `pkill -f` on this scratch path would also
# match the harness that mentions it.
on_exit 'bash "$LAB_FC" destroy '"$NAME"' --force >/dev/null 2>&1 || true'

# ── the guest: same rootfs, with its sysinit replaced by a backgrounded ticker ──────────
R="$tmp/tick.ext4"
cp -- "$BASE" "$R" || skip "could not copy the base rootfs"
# A guest killed mid-run leaves a dirty bitmap that debugfs refuses to open. Repair the
# COPY (never the original — other tests boot it).
e2fsck -fy "$R" >/dev/null 2>&1 || true
cat > "$tmp/mc-probe.sh" <<'EOS'
#!/bin/sh
( i=0; while :; do i=$((i+1)); echo "MC-TICK $i" > /dev/console; sleep 1; done ) &
EOS
debugfs -w -R "rm /mc-probe.sh" "$R" >/dev/null 2>&1 || true
debugfs -w -R "write $tmp/mc-probe.sh mc-probe.sh" "$R" >/dev/null 2>&1 \
    || skip "debugfs could not inject the ticker into the rootfs copy"
debugfs -w -R "sif /mc-probe.sh mode 0100755" "$R" >/dev/null 2>&1 || true
debugfs -R "stat /mc-probe.sh" "$R" 2>/dev/null | grep -q 'Mode:  0755' \
    || skip "the injected ticker is not executable in the image — the guest would not run it"

out="$(bash "$LAB_FC" create --name "$NAME" --kernel "$KERNEL" --rootfs "$R" --memory 256M 2>&1)" \
    || fail "create failed: $out"
out="$(bash "$LAB_FC" start "$NAME" 2>&1)" || fail "start failed: $out"
LOG="$LAB_STATE_DIR/fc/$NAME/fc.log"

# `|| true` is load-bearing, not defensive noise. With `pipefail` on, a `grep` that matches
# NOTHING makes the whole pipeline return 1, which makes `t="$(last_tick …)"` a failing
# command, which under `set -e` ends the test — before the guest has printed its first tick,
# i.e. every single time. The first draft of this test passed only because it happened to
# look after the guest was already ticking. The status is not the gate here; the OUTPUT is.
last_tick() { grep -o 'MC-TICK [0-9]*' "$1" 2>/dev/null | tail -1 | awk '{print $2}' || true; }
first_tick_after() { tail -c +$(($2 + 1)) "$1" | grep -o 'MC-TICK [0-9]*' | head -1 | awk '{print $2}' || true; }

# ── the guest must actually be ticking, or every assertion below is vacuous ─────────────
# Wait for tick 4, not merely for tick 1. With a snapshot at tick 1 the three assertions
# below all collapse into "is it 2?", and a test whose arithmetic has no room cannot tell a
# real restore from an off-by-one. Letting it run first puts real distance between the
# captured value, the value the live VM reached, and 1.
# `if`, not `[[ … ]] && (( … )) && break`: as a bare statement that list returns 1 the
# moment its first guard is false, and under `set -e` that ends the test — with no verdict,
# which is precisely what the lib's EXIT net caught when this was written the short way.
# The same shape is called out in test-engine-routing-all-paths.sh. A condition context is
# the fix; `|| true` would work too and would also silence a real failure.
for _ in $(seq 1 60); do
    t="$(last_tick "$LOG")"
    if [[ -n "$t" ]] && (( t >= 4 )); then break; fi
    sleep 1
done
before="$(last_tick "$LOG")"
[[ -n "$before" ]] \
    || fail "the guest never printed a tick in 60 s — it did not boot, so nothing here could be measured (see $LOG)"
(( before >= 4 )) \
    || fail "the guest only reached tick $before in 60 s — too slow to distinguish a restore from a reboot; nothing was measured"
note "guest is ticking (at $before)"

# The API socket is the whole enabling change: --no-api had nowhere to receive these calls.
[[ -S "$LAB_STATE_DIR/fc/$NAME/api.sock" ]] \
    || fail "REGRESSION: start created no API socket — snapshot/create and snapshot/load are API-only, so this is the blocker returning"

# ── snapshot, and the VM must survive it ────────────────────────────────────────────────
out="$(bash "$LAB_FC" snapshot create "$NAME" warm 2>&1)" || fail "snapshot create failed: $out"
at_snapshot="$(last_tick "$LOG")"
sd="$LAB_STATE_DIR/fc/$NAME/snapshots/warm"
for f in vmstate mem rootfs.ext4 snapshot.toml; do
    [[ -s "$sd/$f" ]] || fail "snapshot create reported success and left no $f — the liar case"
done
# A snapshot that stopped the VM would be a different verb. §9.5's fast tier exists to keep
# a RUNNING thing running.
# Let it run WELL past the capture, so "rewound" is a large, unambiguous step backwards.
for _ in $(seq 1 30); do
    t="$(last_tick "$LOG")"
    if [[ -n "$t" ]] && (( t >= at_snapshot + 4 )); then break; fi
    sleep 1
done
after_snap="$(last_tick "$LOG")"
(( after_snap > at_snapshot )) \
    || fail "REGRESSION: the guest stopped ticking after snapshot create — it was left PAUSED (at $at_snapshot, still $after_snap)"
note "snapshot taken at tick $at_snapshot; guest resumed and ran on to $after_snap"

# ── stop, restore, and read ONLY what the restored VMM wrote ────────────────────────────
out="$(bash "$LAB_FC" stop "$NAME" 2>&1)" || fail "stop failed: $out"
ran_to="$(last_tick "$LOG")"
mark="$(wc -c < "$LOG")"
(( ran_to > at_snapshot )) \
    || fail "the guest did not advance past the snapshot before being stopped ($ran_to vs $at_snapshot) — continuity could not be distinguished from a no-op"

out="$(bash "$LAB_FC" snapshot restore "$NAME" warm 2>&1)" || fail "snapshot restore failed: $out"
for _ in $(seq 1 30); do
    if [[ -n "$(first_tick_after "$LOG" "$mark")" ]]; then break; fi
    sleep 1
done
first_after="$(first_tick_after "$LOG" "$mark")"
[[ -n "$first_after" ]] \
    || fail "the restored guest printed no tick in 30 s — it is not running (see $LOG past byte $mark)"

# THE ASSERTION. Restored → continues from the captured value. Rebooted → restarts at 1.
(( first_after <= at_snapshot + 2 && first_after > 0 )) \
    || fail "REGRESSION: the restored guest is not the captured one — the snapshot was taken at tick $at_snapshot and the restored guest's first tick is $first_after (a fresh boot restarts at 1; a guest that kept running would be past $ran_to)"
(( first_after != 1 )) \
    || fail "REGRESSION: the restored guest REBOOTED — its counter restarted at 1, so snapshot/load did not resume memory"
(( first_after < ran_to )) \
    || fail "REGRESSION: the guest did not rewind to the snapshot — it reached $ran_to before the stop and resumed at $first_after, so the memory image was not what came back"

# The complementary half: a reboot would have reprinted the kernel banner. Read past the
# mark only, for the reason in the header.
if tail -c +$((mark + 1)) "$LOG" | grep -qE 'Linux version|Welcome to Alpine'; then
    fail "REGRESSION: the restored VMM printed a kernel boot banner — it booted a new guest instead of resuming the snapshot"
fi

note "restored guest resumed at tick $first_after (snapshot: $at_snapshot, live VM had reached $ran_to) with no boot banner"
pass "a real Firecracker guest was snapshotted while running, stopped, and restored to the captured INSTANT — its counter resumed at $first_after rather than restarting, and no kernel banner was reprinted"
