#!/usr/bin/env bash
# §14 slice 8's exercise: FIVE warm clones from ONE memory image, and the three claims that
# sentence quietly makes.
#
# The sibling phase7-firecracker/tests/test-clone-refusals.sh covers every gate with no VMM
# at all and runs in CI. This one needs a real Firecracker, real KVM and a real bootable
# guest, because the properties here are not "the tool issued the right API calls" — they are
# facts about five machines that are actually running, and no stand-in can answer them.
#
# ── THE THREE CLAIMS, AND HOW EACH IS MEASURED ──────────────────────────────────────────
#
#   1. "warm"  — every clone RESUMED the captured instant rather than booting.
#      Measured from a monotonic counter the guest prints to its console, exactly as
#      phase7's test-snapshot-round-trip.sh does: a restore continues from N, a fresh boot
#      restarts at 1. A marker FILE could not tell those apart, because the rootfs is copied
#      into the snapshot and a rebooted guest would find the same file and "pass".
#
#   2. "from ONE memory image" — the mem file is SHARED, not copied per clone.
#      Measured as the mem file's sha256 being UNCHANGED after five clones have been running
#      and writing for seconds. Firecracker maps a `File` mem backend MAP_PRIVATE, so each
#      clone's writes are private to it; if that were ever to change, or if `clone` were to
#      quietly start copying, this digest is the thing that moves. It is the difference
#      between 256 MiB for the fleet and 256 MiB EACH.
#
#   3. each clone got its OWN disk.
#      Measured by digest divergence: the five rootfs files start byte-identical (they are
#      copies of one snapshot) and must DIFFER from each other once the guests have written,
#      while the snapshot's own copy stays exactly as it was captured. Asserting that
#      `clone` issued a `PATCH /drives` would be asserting the mechanism; five files that
#      have diverged is the outcome, and it is the one that says nobody is scribbling on
#      anybody.
#
# ── AND THE HAZARD, WHICH IS NOT A BUG HERE BUT THE LESSON ──────────────────────────────
# The same console line carries a secret the guest read from /dev/urandom BEFORE the
# snapshot, and its boot_id. Both are identical across all five, because copying memory
# copies identity. That is asserted too — as a property the fleet HAS, not one it lacks —
# so that a future `clone` which quietly began re-personalising would have to say so.
# The full 2x2 (VMGenID on/off x read-timing) is examples/micro-cloud/tests/test-clone-entropy.sh.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
need sha256sum e2fsck debugfs curl awk

FC_TOOL="$REPO_DIR/phase7-firecracker/lab-fc.sh"
[[ -x "$FC_TOOL" ]] || skip "lab-fc.sh not executable at $FC_TOOL"

W="${MC_WORKDIR:-$(mc_workdir)}"
KERNEL="${MC_KERNEL:-$W/vmlinux}"
BASE="${MC_ROOTFS:-$W/api1.ext4}"

# The VMM is looked for WHERE THIS REPO PUTS IT, not only on PATH: slice 1 fetched the pinned
# binary into the micro-cloud workdir rather than installing it system-wide, so requiring it
# on PATH would make this SKIP on the one machine that can run it.
if ! have firecracker; then
    [[ -x "$W/firecracker" ]] || skip "no firecracker on PATH and none at $W/firecracker — nothing to clone"
    PATH="$W:$PATH"; export PATH
fi
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] \
    || skip "/dev/kvm is not read-write for uid $EUID — a clone resumes a RUNNING guest, and there is none without KVM"
[[ -r "$KERNEL" ]] || skip "no bootable kernel at $KERNEL (slice 1/3 artifacts absent) — nothing to boot"
[[ -r "$BASE"   ]] || skip "no bootable rootfs at $BASE (slice 1/3 artifacts absent) — nothing to boot"

# SHORT PATH, DELIBERATELY. `sockaddr_un.sun_path` is 108 bytes including the NUL, and
# lab-fc.sh puts each instance's API socket inside its state dir. Under a long scratch path
# it falls back to a derived short name and still works — but this test creates SIX
# instances, and it should exercise the ordinary path rather than the fallback. Found the
# hard way: the first spike for this test ran under the agent scratch dir and curl refused
# every call with "Unix socket path too long" before a single clone was made.
tmp="$(mktemp -d /tmp/mcfleet.XXXXXX)"; on_exit 'rm -rf -- "$tmp"'
export LAB_STATE_DIR="$tmp/state"
SRC=fsrc
CLONES=(w1 w2 w3 w4 w5)

# Teardown registered BEFORE anything is created, so it runs however this ends — and BY NAME
# through the tool's own verb, never a pattern. `pkill -f` on this scratch path would also
# match the harness that mentions it, and this repo has killed a QEMU VM and its own shell
# exactly that way.
on_exit 'for _c in '"${CLONES[*]}"' '"$SRC"'; do bash "'"$FC_TOOL"'" destroy "$_c" --force >/dev/null 2>&1 || true; done'

# ── the guest: the base rootfs with a ticker that also carries its identity ─────────────
R="$tmp/tick.ext4"
cp -- "$BASE" "$R" || skip "could not copy the base rootfs"
# A guest killed mid-run leaves a dirty bitmap debugfs refuses to open. Repair the COPY —
# never the original, which other tests boot.
e2fsck -fy "$R" >/dev/null 2>&1 || true
# The ticker is BACKGROUNDED from a sysinit action: busybox init runs every `sysinit` entry
# to completion before it starts any `respawn` one, so a ticker registered as `respawn` would
# not exist for the guest's first ~40 s (measured in slice 5c).
# THE PROBE WRITES TO ITS DISK, AND THAT LINE IS THE WHOLE OF CLAIM 3.
# The first version of this test printed to the console only, so no guest ever dirtied a
# block; the five rootfs copies stayed byte-identical and the divergence assertion fired on
# its own premise rather than on a defect. A test that asserts "these files differ" has to
# make something write to them, or it is measuring nothing and saying so loudly.
# `sync` because ext4 would otherwise hold the write in the guest's page cache and the host
# would see the change whenever it felt like it — which is a race, not a measurement.
cat > "$tmp/mc-probe.sh" <<'EOS'
#!/bin/sh
SEC=$(head -c8 /dev/urandom | od -An -tx1 | tr -d " \n")
( i=0; while :; do i=$((i+1))
  head -c 64 /dev/urandom > /mc-marker; sync
  echo "MC-TICK $i SECRET $SEC BOOTID $(cat /proc/sys/kernel/random/boot_id)" > /dev/console
  sleep 1; done ) &
EOS
debugfs -w -R "rm /mc-probe.sh" "$R" >/dev/null 2>&1 || true
debugfs -w -R "write $tmp/mc-probe.sh mc-probe.sh" "$R" >/dev/null 2>&1 \
    || skip "debugfs could not inject the probe into the rootfs copy"
debugfs -w -R "sif /mc-probe.sh mode 0100755" "$R" >/dev/null 2>&1 || true
debugfs -R "stat /mc-probe.sh" "$R" 2>/dev/null | grep -q 'Mode:  0755' \
    || skip "the injected probe is not executable in the image — the guest would not run it"

fc() { bash "$FC_TOOL" "$@"; }
# `|| true` is load-bearing: with `pipefail` on, a grep that matches NOTHING makes the whole
# pipeline return 1, which makes `t="$(last_tick …)"` the failing command. The status is not
# the gate here; the OUTPUT is.
last_tick() { grep -o 'MC-TICK [0-9]*' "$1" 2>/dev/null | tail -1 | awk '{print $2}' || true; }
field_after() { grep -o "MC-TICK [0-9]* SECRET [0-9a-f]* BOOTID [0-9a-f-]*" "$1" 2>/dev/null | head -1 | awk "{print \$$2}" || true; }
sha() { sha256sum -- "$1" | cut -d' ' -f1; }

out="$(fc create --name "$SRC" --kernel "$KERNEL" --rootfs "$R" --memory 256M 2>&1)" || fail "create failed: $out"
out="$(fc start "$SRC" 2>&1)" || fail "start failed: $out"
LOG="$LAB_STATE_DIR/fc/$SRC/fc.log"

# Wait for tick 4, not merely tick 1: with a snapshot at tick 1 every arithmetic assertion
# below collapses into "is it 2?", and a test whose arithmetic has no room cannot tell a real
# resume from an off-by-one.
# `if`, not `[[ … ]] && (( … )) && break` — as a bare statement that list returns 1 the moment
# its first guard is false, and under `set -e` that ends the test with no verdict at all.
for _ in $(seq 1 60); do
    t="$(last_tick "$LOG")"
    if [[ -n "$t" ]] && (( t >= 4 )); then break; fi
    sleep 1
done
AT="$(last_tick "$LOG")"
[[ -n "$AT" ]] || fail "the source guest never printed a tick in 60 s — it did not boot, so nothing here could be measured (see $LOG)"
(( AT >= 4 )) || fail "the source guest only reached tick $AT in 60 s — too slow to distinguish a resume from a reboot; nothing was measured"
note "source is ticking (at $AT)"

out="$(fc snapshot create "$SRC" warm 2>&1)" || fail "snapshot create failed: $out"
SD="$LAB_STATE_DIR/fc/$SRC/snapshots/warm"
MEM_BEFORE="$(sha "$SD/mem")"
SNAP_ROOTFS_BEFORE="$(sha "$SD/rootfs.ext4")"
# The SOURCE's own disk, recorded so that the failure below can NAME which of two defects it
# is looking at instead of describing a symptom they share. A clone that was never re-pointed
# writes here, and the difference between "the guest never wrote" and "it wrote to somebody
# else's disk" is the difference between a broken test and a corrupted fleet.
SRC_ROOTFS_BEFORE="$(sha "$LAB_STATE_DIR/fc/$SRC/rootfs.ext4")"
# Stop the source. Not required by `clone` — but leaving it running would mean six guests
# printing the same counter, and the source's own ticks advancing past the captured instant
# would make "did the clone rewind?" a question about the wrong log.
out="$(fc stop "$SRC" 2>&1)" || fail "stop failed: $out"

# ── five clones ─────────────────────────────────────────────────────────────────────────
T0="$(date +%s%N)"
for c in "${CLONES[@]}"; do
    out="$(fc clone "$SRC" warm "$c" 2>&1)" || fail "clone $c failed: $out"
    grep -q 'state=Running' <<<"$out" || fail "clone $c did not report a resumed guest: $out"
done
T1="$(date +%s%N)"
note "five clones issued in $(( (T1 - T0) / 100000000 ))e-1 s (each copies a $(du -h "$SD/rootfs.ext4" | cut -f1) disk; the memory image is shared, not copied)"

# ── CLAIM 1: every clone RESUMED. All five, not "at least one" ───────────────────────────
for c in "${CLONES[@]}"; do
    cl="$LAB_STATE_DIR/fc/$c/fc.log"
    for _ in $(seq 1 30); do [[ -n "$(last_tick "$cl")" ]] && break; sleep 1; done
    first="$(field_after "$cl" 2)"
    [[ -n "$first" ]] || fail "clone $c printed no tick in 30 s — it is not running (see $cl)"
    (( first == AT + 1 )) \
        || fail "REGRESSION: clone $c did not resume the captured instant — the snapshot was taken at tick $AT and $c's first tick is $first (a fresh boot restarts at 1)"
    # The complementary half: a reboot would have reprinted the kernel banner. A clone's log
    # is its own file and starts empty, so no byte offset is needed here.
    grep -qE 'Linux version|Welcome to Alpine' "$cl" \
        && fail "REGRESSION: clone $c printed a kernel boot banner — it booted a new guest instead of resuming the memory image"
done
note "all ${#CLONES[@]} clones resumed at tick $((AT + 1)) with no kernel banner"

# ── CLAIM 2: ONE memory image, shared ───────────────────────────────────────────────────
sleep 3   # let the five guests write to memory for a while before asking
MEM_AFTER="$(sha "$SD/mem")"
[[ "$MEM_AFTER" == "$MEM_BEFORE" ]] \
    || fail "REGRESSION: the shared memory image CHANGED while five clones ran on it ($MEM_BEFORE -> $MEM_AFTER) — a File mem backend must be mapped MAP_PRIVATE, and if it is not, every clone is writing into every other clone's RAM"
for c in "${CLONES[@]}"; do
    grep -qF "clone_mem = \"$SD/mem\"" "$LAB_STATE_DIR/fc/$c/manifest.toml" \
        || fail "clone $c does not record the shared memory image it is reading — nothing binds it to its own provenance"
    [[ ! -e "$LAB_STATE_DIR/fc/$c/mem" ]] \
        || fail "clone $c has a memory image of its OWN — 'five warm clones from ONE memory image' is then false, and the fleet costs 5x the RAM it claims"
done
note "one $(du -h "$SD/mem" | cut -f1) memory image served all ${#CLONES[@]} clones, digest unchanged"

# ── CLAIM 3: each clone got its OWN disk ────────────────────────────────────────────────
# TWO assertions, in this order, because one message cannot say both things. A disk that
# still equals the snapshot means the guest never wrote to it (the test's own premise
# failing); five disks equal to EACH OTHER but not to the snapshot would be the real defect.
declare -A seen=()
for c in "${CLONES[@]}"; do
    d="$LAB_STATE_DIR/fc/$c/rootfs.ext4"
    [[ -s "$d" ]] || fail "clone $c has no rootfs of its own at $d"
    h="$(sha "$d")"
    if [[ "$h" == "$SNAP_ROOTFS_BEFORE" ]]; then
        if [[ "$(sha "$LAB_STATE_DIR/fc/$SRC/rootfs.ext4")" != "$SRC_ROOTFS_BEFORE" ]]; then
            fail "REGRESSION: clone $c's own disk is untouched while '$SRC''s disk HAS changed — the clone was never re-pointed at its own copy, so all ${#CLONES[@]} guests are writing to one file that none of them owns. Nothing errors; they corrupt each other in silence, which is why the PATCH is a hard gate in cmd_clone"
        fi
        fail "clone $c's disk is still byte-for-byte the snapshot's, and so is '$SRC''s — no guest wrote anything, so nothing below could distinguish its own disk from a shared one (the probe writes /mc-marker every tick; is it running?)"
    fi
    [[ -z "${seen[$h]:-}" ]] \
        || fail "REGRESSION: clones $c and ${seen[$h]} have byte-identical disks after both have written — they were never re-pointed at their own copies, so both are writing to '$SRC''s rootfs and each is corrupting the other"
    seen[$h]="$c"
done
[[ "$(sha "$SD/rootfs.ext4")" == "$SNAP_ROOTFS_BEFORE" ]] \
    || fail "REGRESSION: the SNAPSHOT's rootfs changed while the clones ran — a clone is writing into the image every future clone is made from"
note "${#seen[@]} distinct disks for ${#CLONES[@]} clones; the snapshot's own copy is untouched"

# ── THE HAZARD, asserted as a property the fleet HAS ────────────────────────────────────
# Not a defect to be fixed here. It is §5.8's lesson — identity is a property of a running
# thing, and copying memory copies identity — and it is asserted so that a `clone` which
# quietly began re-personalising would have to come and change this line.
sec1="$(field_after "$LAB_STATE_DIR/fc/${CLONES[0]}/fc.log" 4)"
bid1="$(field_after "$LAB_STATE_DIR/fc/${CLONES[0]}/fc.log" 6)"
[[ -n "$sec1" && -n "$bid1" ]] || fail "could not read the identity fields from ${CLONES[0]}'s console — the probe's output shape changed"
for c in "${CLONES[@]:1}"; do
    [[ "$(field_after "$LAB_STATE_DIR/fc/$c/fc.log" 4)" == "$sec1" ]] \
        || fail "clone $c holds a DIFFERENT pre-snapshot secret from ${CLONES[0]} — a clone that re-personalised itself is a change this test must be told about, not one it should pass over"
    [[ "$(field_after "$LAB_STATE_DIR/fc/$c/fc.log" 6)" == "$bid1" ]] \
        || fail "clone $c has a different boot_id from ${CLONES[0]} — see above; this test asserts the hazard is present, because the moment it is not, something re-personalised the guest and the docs are wrong"
done
note "all ${#CLONES[@]} clones share one boot_id ($bid1) and one pre-snapshot secret — the LIED rung, on purpose"

# ── and the source's memory image is a live dependency, refused by name ─────────────────
rc=0; out="$(fc destroy "$SRC" 2>&1)" || rc=$?
(( rc != 0 )) || fail "REGRESSION: destroy removed the memory image five running clones read out of, and said nothing"
grep -q "${CLONES[0]}" <<<"$out" || fail "the refusal does not NAME a dependent clone — a count cannot say which one: $out"

pass "five warm clones from ONE memory image: every clone resumed at tick $((AT + 1)) rather than booting, the ${#CLONES[@]} of them shared a single unchanged $(du -h "$SD/mem" | cut -f1) mem file (MAP_PRIVATE, measured by digest), each got its own disk and they have diverged — and all five still share one boot_id and one pre-snapshot secret, which is the hazard, asserted as present"
