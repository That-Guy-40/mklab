#!/usr/bin/env bash
# §5.8's clone hazard, measured as a 2x2 — because measuring it as a 1x1 gives the wrong
# answer, and this test exists to make that impossible to repeat.
#
# The plan says: *"every restored clone resumes with the same entropy pool… Demonstrate the
# hazard (`head -c8 /dev/urandom | xxd` matching across clones), then fix it by re-seeding on
# resume."* Run exactly that demonstration on this stack and it DOES NOT REPRODUCE — five
# clones print five different values and the hazard looks retired. It is not. Two independent
# things were being conflated, and separating them is what this file is for.
#
# ── WHAT IS MEASURED HERE, AND WHICH HALF IS DETERMINISTIC ──────────────────────────────
#
#   1. VMGenID DISABLED, first read after resume  ->  ALL CLONES IDENTICAL.  (asserted)
#      §5.8's hazard, exactly as written. The memory image is the pool, and copying memory
#      copies it.
#
#   2. …and the SECOND read already differs.      (measured, reported, not asserted)
#      The window is ONE READ WIDE on this host — sub-millisecond. Which is precisely why
#      the demonstration §5.8 prescribes does not reproduce: any probe that pauses before
#      looking samples long past it. The first version of this test slept a second between
#      reads and reported "no hazard" in the row where the hazard is real. That is this
#      repo's oldest lesson pointed at a MEASUREMENT rather than at an assertion — the cheap
#      check is not a weaker version of the real one, it is a different question that
#      happens to be easier to ask, and it can be true while the thing it stands for is
#      false.
#
#   3. VMGenID ACTIVE, the kernel prints its fork-reseed line.   (asserted)
#      Linux's drivers/virt/vmgenid.c sees the generation counter change on `snapshot/load`
#      and calls add_vmfork_randomness(). §5.8's prescribed fix, already in the guest kernel
#      rather than in any tool.
#
#   4. …but WHETHER IT LANDS BEFORE THE FIRST READ IS A RACE.   (measured, NOT asserted)
#      add_vmfork_randomness() runs from the ACPI notify path, not from the resume itself.
#      Measured here across runs: usually the first post-resume read already differs, and
#      sometimes it does not — three clones with VMGenID working produced one identical
#      first read. So VMGenID narrows the window; it does not close it, and a test that
#      asserted "with VMGenID the first read differs" would be asserting a race. It is
#      reported on every run instead, with which way it went.
#
#   5. In BOTH configurations, a secret read BEFORE the snapshot and the guest's boot_id are
#      byte-identical across every clone.   (asserted)
#      VMGenID reseeds the CRNG. It does not re-personalise the machine. Reseeding on resume
#      fixes the randomness not yet asked for — it cannot fix the session keys already minted
#      from it, and that is the version of §5.8's lesson that survives contact with a kernel
#      which already implements §5.8's fix.
#
# ── HOW VMGENID IS TURNED OFF, AND WHY THE SYMBOL HAS A TYPO IN IT ──────────────────────
# Firecracker exposes a VMGenID device; Linux's drivers/virt/vmgenid.c sees the generation
# counter change on `snapshot/load` and calls add_vmfork_randomness(), which is what prints
#     random: crng reseeded due to virtual machine fork
# The control disables it with `initcall_blacklist=<initcall>`. The first attempt used
# `vmgenid_driver_init`, the name the driver's `module_platform_driver()` macro *ought* to
# generate — the kernel silently ignored it, the reseed still fired, and the control appeared
# to prove the opposite of the truth. The real symbol is `vmgenid_plaform_driver_init`:
# upstream's variable is misspelled. Printed from the kernel binary with `strings`, not
# guessed. Hence assertion 3 below: the control is only trusted when the reseed message is
# OBSERVED to disappear.
#
# ── AND THE HALF NO RESEED FIXES ────────────────────────────────────────────────────────
# In every cell, a secret the guest read BEFORE the snapshot and the guest's boot_id are
# byte-identical across all clones. VMGenID reseeds the CRNG; it does not re-personalise the
# machine. Reseeding on resume fixes the randomness you have not asked for yet — it cannot
# fix the session keys you already minted. That is the version of §5.8's lesson that survives
# contact with a kernel that already implements §5.8's prescribed fix.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
need sha256sum e2fsck debugfs curl awk strings

FC_TOOL="$REPO_DIR/phase7-firecracker/lab-fc.sh"
[[ -x "$FC_TOOL" ]] || skip "lab-fc.sh not executable at $FC_TOOL"

W="${MC_WORKDIR:-$(mc_workdir)}"
KERNEL="${MC_KERNEL:-$W/vmlinux}"
BASE="${MC_ROOTFS:-$W/api1.ext4}"
if ! have firecracker; then
    [[ -x "$W/firecracker" ]] || skip "no firecracker on PATH and none at $W/firecracker — nothing to clone"
    PATH="$W:$PATH"; export PATH
fi
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] \
    || skip "/dev/kvm is not read-write for uid $EUID — the entropy pool under test lives in a running guest"
[[ -r "$KERNEL" ]] || skip "no bootable kernel at $KERNEL (slice 1/3 artifacts absent) — nothing to boot"
[[ -r "$BASE"   ]] || skip "no bootable rootfs at $BASE (slice 1/3 artifacts absent) — nothing to boot"

# The control needs a symbol that is IN THIS KERNEL. Blacklisting a name the kernel does not
# have is silently a no-op — which is exactly how the first version of this test "proved"
# the hazard was gone. Refuse to run rather than run blind.
# NOT `strings … | grep -q …`. With `pipefail` on, `grep -q` exits at the first match, the
# still-writing `strings` takes SIGPIPE, and the PIPELINE reports 141 — so the check refuses
# precisely when the symbol IS present. It cost a run here, and this repo has the gotcha
# written down already. Capture and test the value instead; `grep -F` reads to EOF.
_vmgenid_sym="$(strings -a "$KERNEL" 2>/dev/null | grep -Fx 'vmgenid_plaform_driver_init' || true)"
[[ -n "$_vmgenid_sym" ]] \
    || skip "this kernel has no 'vmgenid_plaform_driver_init' initcall to blacklist — the negative control could not be armed, and a run without it cannot tell the fix from the absence of the hazard"

# Short path: sun_path is 108 bytes including the NUL, and this test creates eight instances.
tmp="$(mktemp -d /tmp/mcent.XXXXXX)"; on_exit 'rm -rf -- "$tmp"'
export LAB_STATE_DIR="$tmp/state"
ALL=(gsrc bsrc g1 g2 g3 b1 b2 b3)
on_exit 'for _i in '"${ALL[*]}"'; do bash "'"$FC_TOOL"'" destroy "$_i" --force >/dev/null 2>&1 || true; done'

# ── the probe: a TIGHT loop. No sleep — that is the independent variable ────────────────
R="$tmp/ent.ext4"
cp -- "$BASE" "$R" || skip "could not copy the base rootfs"
e2fsck -fy "$R" >/dev/null 2>&1 || true
cat > "$tmp/mc-probe.sh" <<'EOS'
#!/bin/sh
SEC=$(head -c8 /dev/urandom | od -An -tx1 | tr -d " \n")
BID=$(cat /proc/sys/kernel/random/boot_id)
( i=0; while :; do i=$((i+1))
  echo "MC-R $i $(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n') $SEC $BID" > /dev/console
done ) &
EOS
debugfs -w -R "rm /mc-probe.sh" "$R" >/dev/null 2>&1 || true
debugfs -w -R "write $tmp/mc-probe.sh mc-probe.sh" "$R" >/dev/null 2>&1 \
    || skip "debugfs could not inject the probe into the rootfs copy"
debugfs -w -R "sif /mc-probe.sh mode 0100755" "$R" >/dev/null 2>&1 || true
debugfs -R "stat /mc-probe.sh" "$R" 2>/dev/null | grep -q 'Mode:  0755' \
    || skip "the injected probe is not executable in the image — the guest would not run it"

fc() { bash "$FC_TOOL" "$@"; }
# `|| true` throughout: with `pipefail`, a grep matching nothing makes the ASSIGNMENT the
# failing command and ends the test under `set -e` — before the guest has printed anything,
# i.e. every time. The output is the gate here, not the status.
last_n()  { grep -o 'MC-R [0-9]*' "$1" 2>/dev/null | tail -1 | awk '{print $2}' || true; }
# THE FIRST COMPLETE RECORD IN A CLONE'S LOG, which is the only index worth comparing at.
# The obvious alternative — "the read the source was at when it was snapshotted, plus one" —
# is not knowable from the host: `snapshot create` resumes the VM, so by the time the log can
# be read the source has counted on past the captured instant. Asking the CLONES where they
# started is asking the thing that actually knows. `-m1 -o` over the full record also steps
# over a fragment: the guest may have been paused mid-`echo`, and half a line is not a read.
first_n() { grep -m1 -o "MC-R [0-9]* [0-9a-f]* [0-9a-f]* [0-9a-f-]*" "$1" 2>/dev/null | awk '{print $2}' || true; }
at_n()    { grep -m1 -o "MC-R $2 [0-9a-f]* [0-9a-f]* [0-9a-f-]*" "$1" 2>/dev/null | awk '{print $3}' || true; }
sec_of()  { grep -m1 -o "MC-R [0-9]* [0-9a-f]* [0-9a-f]* [0-9a-f-]*" "$1" 2>/dev/null | awk '{print $4}' || true; }
bid_of()  { grep -m1 -o "MC-R [0-9]* [0-9a-f]* [0-9a-f]* [0-9a-f-]*" "$1" 2>/dev/null | awk '{print $5}' || true; }

# boot_and_snap <instance> [extra-append...] -> echoes the read number the snapshot was taken at
# EVERY STAGE ANNOUNCES ITSELF, AND THAT IS NOT DECORATION.
#
# This function makes four tool calls and waits up to 60 s, and it used to print NOTHING on
# the way. When a run died inside it the whole record was one line — `booting the …source…`
# — followed by whatever the shell had to say, which is not enough to tell `create` from
# `start` from a guest that never counted. A day was spent on exactly that: a truncated log
# was read as a defect in this test, and the missing information was simply *where it had
# got to*. Every `fail` below already names its own defect; these notes name the STAGE, so
# even a death that produces no verdict at all (a signal, an OOM, a host reboot) leaves the
# reader pointing at one command instead of at four.
boot_and_snap() {
    local n="$1"; shift
    local -a extra=()
    (( $# )) && extra=(--append "$1")
    local o
    note "  [$n] create"
    o="$(fc create --name "$n" --kernel "$KERNEL" --rootfs "$R" --memory 256M ${extra+"${extra[@]}"} 2>&1)" \
        || fail "create $n failed: $o"
    note "  [$n] start"
    o="$(fc start "$n" 2>&1)" || fail "start $n failed: $o"
    note "  [$n] waiting for the guest to reach read 50 (up to 60 s)"
    local lg="$LAB_STATE_DIR/fc/$n/fc.log" t=""
    for _ in $(seq 1 60); do
        t="$(last_n "$lg")"
        if [[ -n "$t" ]] && (( t >= 50 )); then break; fi
        sleep 1
    done
    [[ -n "$t" ]] || fail "$n never printed a read in 60 s — it did not boot, so nothing here could be measured (see $lg)"
    (( t >= 50 )) || fail "$n only reached read $t in 60 s — the probe is not looping tightly, and the whole point of this test is the width of the window between resume and the first read"
    note "  [$n] snapshot create (pauses, captures memory + devices, resumes)"
    o="$(fc snapshot create "$n" warm 2>&1)" || fail "snapshot create $n failed: $o"
    note "  [$n] stop"
    o="$(fc stop "$n" 2>&1)" || fail "stop $n failed: $o"
    printf '%s' "$(last_n "$lg")"
}

# clones_of <src> <c1> <c2> <c3> — clone, then wait until each has printed something
clones_of() {
    local src="$1"; shift
    local c o
    for c in "$@"; do
        note "  [$src -> $c] clone"
        o="$(fc clone "$src" warm "$c" 2>&1)" || fail "clone $src -> $c failed: $o"
    done
    for c in "$@"; do
        for _ in $(seq 1 30); do [[ -n "$(last_n "$LAB_STATE_DIR/fc/$c/fc.log")" ]] && break; sleep 1; done
        [[ -n "$(last_n "$LAB_STATE_DIR/fc/$c/fc.log")" ]] \
            || fail "clone $c printed no read in 30 s — it is not running (see $LAB_STATE_DIR/fc/$c/fc.log)"
    done
}

# resume_index <clones…> — SETS $RESUME_N to the read index every clone has in common.
#
# IT SETS A VARIABLE RATHER THAN PRINTING ONE, and that is not a style choice. `fail` is an
# `exit`, and an `exit` inside `n="$(resume_index …)"` ends only the command substitution:
# the caller carries on with an EMPTY value and fails later wearing someone else's clothes.
# That happened here — a real refusal printed its FAIL line and was then followed by a second,
# nonsensical one about "read #" with no number. lab-fc.sh's `_name_arg` has the same shape
# for the same reason, and this repo has the gotcha written down.
#
# WHY IT IS NOT SIMPLY "they must all agree". Measured: two clones of one memory image can
# report first indices 800 and 801. The guest was paused mid-`echo`, so the first thing a
# resumed clone writes is the REMAINDER of a line, and whether that remainder still parses as
# a whole record is a property of where in the write the pause fell. One index of slack is
# that fragment; more than one would mean something actually diverged — a clone that booted
# instead of resuming starts at 1 — so the tolerance is exactly one and anything wider is a
# named failure.
RESUME_N=""
resume_index() {
    local c n lo="" hi=""
    for c in "$@"; do
        n="$(first_n "$LAB_STATE_DIR/fc/$c/fc.log")"
        [[ -n "$n" ]] || fail "clone $c has no complete read in its log — it printed nothing, or only a fragment (see $LAB_STATE_DIR/fc/$c/fc.log)"
        [[ -z "$lo" ]] && { lo="$n"; hi="$n"; }
        (( n < lo )) && lo="$n"
        (( n > hi )) && hi="$n"
    done
    (( hi - lo <= 1 )) \
        || fail "REGRESSION: clones resumed into read indices $lo…$hi — they were made from one memory image, so a spread wider than the one-line fragment means at least one of them booted rather than resumed (a fresh boot starts at 1)"
    # The HIGHEST first-index is the earliest read every clone is guaranteed to have.
    RESUME_N="$hi"
    local missing=()
    for c in "$@"; do
        [[ -n "$(at_n "$LAB_STATE_DIR/fc/$c/fc.log" "$RESUME_N")" ]] || missing+=("$c")
    done
    (( ${#missing[@]} == 0 )) \
        || fail "read #$RESUME_N is absent from ${missing[*]} — the clones have no read index in common, so there is nothing to compare them at"
}

# ── ROW 1: VMGenID ACTIVE (the default, and what an operator actually gets) ─────────────
note "booting the VMGenID-active source…"
boot_and_snap gsrc > /dev/null
clones_of gsrc g1 g2 g3
# EVERY CLONE'S FIRST READ MUST CARRY THE SAME INDEX. That is continuity — three machines
# picking up one counter at the same value — and it is also what makes the entropy comparison
# below have a common subject at all. Without it, "the three values differ" could just mean
# the three were sampled at three different moments.
resume_index g1 g2 g3; GN="$RESUME_N"
ga="$(at_n "$LAB_STATE_DIR/fc/g1/fc.log" "$GN")"
gb="$(at_n "$LAB_STATE_DIR/fc/g2/fc.log" "$GN")"
gc="$(at_n "$LAB_STATE_DIR/fc/g3/fc.log" "$GN")"
[[ -n "$ga" && -n "$gb" && -n "$gc" ]] \
    || fail "could not read read #$GN from all three VMGenID-active clones (g1='$ga' g2='$gb' g3='$gc')"
# THE ASSERTION IS THAT THE FIX FIRED, NOT THAT IT WON THE RACE. add_vmfork_randomness()
# runs from the ACPI notify path rather than from the resume, so whether the reseed lands
# before the guest's first read is a matter of scheduling. Asserting "the first read differs"
# would be asserting a race — and it did lose one, here, during this test's own development:
# three clones with VMGenID demonstrably working produced one identical first read. Which way
# it went is REPORTED on every run, because a narrowed window is not a closed one and the
# difference matters to anyone minting a key on resume.
for c in g1 g2 g3; do
    grep -qa 'crng reseeded due to virtual machine fork' "$LAB_STATE_DIR/fc/$c/fc.log" \
        || fail "REGRESSION: clone $c never printed the fork-reseed line — VMGenID is not firing on this stack, so §5.8's fix is absent and every clone of this image shares its pool for as long as the pool lasts"
done
if [[ "$ga" == "$gb" && "$gb" == "$gc" ]]; then
    note "VMGenID active: the reseed FIRED in all three, but LOST the race — read #$GN is still identical across the three ($ga). The window is narrowed, not closed."
else
    note "VMGenID active: reseed fired in all three and won the race — read #$GN already differs ($ga / $gb / $gc)"
fi

# ── ROW 2: VMGenID DISABLED — the hazard, reproduced ────────────────────────────────────
note "booting the VMGenID-disabled source…"
boot_and_snap bsrc initcall_blacklist=vmgenid_plaform_driver_init > /dev/null
clones_of bsrc b1 b2 b3
resume_index b1 b2 b3; BN="$RESUME_N"

# THE CONTROL IS ONLY TRUSTED WHEN IT IS OBSERVED TO HAVE TAKEN EFFECT. Blacklisting a
# misspelled symbol is a silent no-op, and a silent no-op here would make the assertion below
# fail and be read as "the hazard does not exist on this stack" — the exact wrong conclusion.
for c in b1 b2 b3; do
    grep -qa 'crng reseeded due to virtual machine fork' "$LAB_STATE_DIR/fc/$c/fc.log" \
        && fail "the negative control did NOT take: clone $c still printed the fork-reseed line, so VMGenID is still running and nothing below is measuring what it claims"
done

ba="$(at_n "$LAB_STATE_DIR/fc/b1/fc.log" "$BN")"
bb="$(at_n "$LAB_STATE_DIR/fc/b2/fc.log" "$BN")"
bc="$(at_n "$LAB_STATE_DIR/fc/b3/fc.log" "$BN")"
[[ -n "$ba" && -n "$bb" && -n "$bc" ]] \
    || fail "could not read read #$BN from all three VMGenID-disabled clones (b1='$ba' b2='$bb' b3='$bc')"
[[ "$ba" == "$bb" && "$bb" == "$bc" ]] \
    || fail "with VMGenID DISABLED, three clones from one memory image produced DIFFERENT first post-resume reads ($ba / $bb / $bc). Either something else is re-seeding the pool, or the read is landing further from the resume than this test believes — and in both cases the hazard §5.8 is built on has stopped being demonstrable here, which is a finding that has to be written down rather than passed over"
note "VMGenID disabled: three clones, ONE value ($ba) at read #$BN — §5.8's hazard, reproduced"

# ── HOW WIDE THE WINDOW IS, WHICH IS WHY THE PRESCRIBED DEMONSTRATION FAILS ─────────────
# Walk forward until the three separate. This is MEASURED and REPORTED, never asserted: it
# is a property of this host's scheduling, and pinning a number here would be caching a
# fact whose subject is the machine it ran on. The value is the point — on this host it
# has been ONE read, sub-millisecond, so any probe that pauses before looking samples long
# past the hazard and reports that there isn't one.
# Let the three run on first. The walk below stops at the first read index that is not yet
# present in ALL THREE logs, so measuring it the instant the clones came up reported UNKNOWN
# because one of them had printed four lines — an honest UNKNOWN about a question that only
# needed a few more seconds to be answerable.
WALK=400
for _ in $(seq 1 60); do
    _lo="$(last_n "$LAB_STATE_DIR/fc/b1/fc.log")"; _lb="$(last_n "$LAB_STATE_DIR/fc/b2/fc.log")"; _lc="$(last_n "$LAB_STATE_DIR/fc/b3/fc.log")"
    if [[ -n "$_lo" && -n "$_lb" && -n "$_lc" ]] && (( _lo > BN + WALK && _lb > BN + WALK && _lc > BN + WALK )); then break; fi
    sleep 1
done
WIDTH=""
for _o in $(seq 0 "$WALK"); do
    _n=$(( BN + _o ))
    _a="$(at_n "$LAB_STATE_DIR/fc/b1/fc.log" "$_n")"
    _b="$(at_n "$LAB_STATE_DIR/fc/b2/fc.log" "$_n")"
    _c="$(at_n "$LAB_STATE_DIR/fc/b3/fc.log" "$_n")"
    [[ -n "$_a" && -n "$_b" && -n "$_c" ]] || break
    if [[ "$_a" != "$_b" || "$_b" != "$_c" ]]; then WIDTH="$_o"; break; fi
done
if [[ -n "$WIDTH" ]]; then
    note "the shared-pool window was $WIDTH read(s) wide: read #$(( BN + WIDTH )) already differs across the three. A probe with a \`sleep 1\` before its first read samples thousands of reads past that and reports 'no hazard' — which is the probe this file started life with"
else
    note "UNKNOWN: the three had not separated within the $WALK reads after #$BN that are present in all three logs — the WIDTH of the window was NOT measured on this run. That is a fact about how much ambient entropy this host happened to mix in, not about the hazard: the identical-at-resume assertion above stands on its own"
fi

# ── WHAT NO RESEED FIXES, in BOTH rows ──────────────────────────────────────────────────
for pair in "gsrc g1 g2 g3" "bsrc b1 b2 b3"; do
    set -- $pair; src="$1"; shift
    s1="$(sec_of "$LAB_STATE_DIR/fc/$1/fc.log")"; d1="$(bid_of "$LAB_STATE_DIR/fc/$1/fc.log")"
    [[ -n "$s1" && -n "$d1" ]] || fail "could not read the identity fields from $1's console — the probe's output shape changed"
    for c in "$@"; do
        [[ "$(sec_of "$LAB_STATE_DIR/fc/$c/fc.log")" == "$s1" ]] \
            || fail "clone $c of $src holds a different PRE-SNAPSHOT secret from $1 — that value was in memory when the snapshot was taken, so a difference means the memory image is not what came back"
        [[ "$(bid_of "$LAB_STATE_DIR/fc/$c/fc.log")" == "$d1" ]] \
            || fail "clone $c of $src has a different boot_id from $1 — VMGenID reseeds the CRNG and nothing else, so if boot_id has started changing, something re-personalises the guest now and every document here saying otherwise is wrong"
    done
    note "$src's clones: one boot_id ($d1) and one pre-snapshot secret ($s1) across all three — unchanged by whether VMGenID fired"
done

pass "§5.8's clone hazard, reproduced and bounded: with VMGenID disabled, three clones from one memory image produced the SAME first post-resume /dev/urandom read ($ba) and separated ${WIDTH:-an UNMEASURED number of} read(s) later — a window narrow enough that the demonstration §5.8 prescribes misses it entirely. With VMGenID active the guest kernel's fork-reseed fired in all three, which narrows that window without closing it (it is an async ACPI notify, and this run's outcome is in the notes above). In BOTH configurations every clone kept the source's boot_id and the secret it had already derived: reseeding on resume fixes the randomness not yet asked for, never the identity already minted from it"
