#!/usr/bin/env bash
# openbios-check-reproducible.sh — TODO 17.5: is the same tree the same bytes?
#
# §17.5 recorded "rebuilding the same tree produces a different
# openbios-builtin.elf32, and the differing bytes sit inside the embedded
# dictionary -- something dated is baked in during bootstrap", and left it
# there. This chases it, and the answer has TWO causes rather than one.
#
# CAUSE 1, both arches: Makefile.target generates obj-<arch>/forth/version.fs
# with `date +'%b %e %Y %H:%M'` and compiles it into the dictionary. Exactly two
# bytes of the x86 dictionary move between builds a minute apart -- the minute
# digits.
#
# THE DATE IS NOT NOISE, WHICH IS WHY IT IS NOT SIMPLY DELETED.
# smoke-openbios.sh's ppc track proves the running firmware is OURS rather than
# the distro's -bios blob by comparing exactly this banner. Removing it would
# delete an identity check to buy a property nothing had asked for. So the build
# honours SOURCE_DATE_EPOCH -- the reproducible-builds standard -- and is
# unchanged when it is unset.
#
# CAUSE 2, amd64 ONLY, was NOT in the record, and is now FIXED (patch 48). With
# the date pinned the amd64 dictionary used to differ by ~79 bytes: the cell
# holding `end-mem` read
#     build A  0000 7322 4a7d e018
#     build B  0000 70d9 f729 c018
# -- canonical Linux userspace addresses. A HOST POINTER was baked into the
# shipped dictionary and moved with ASLR. kernel/bootstrap.c now scrubs those
# cells out of everything it writes; see scrub_host_arena_ptr() there for why
# zeroing them is safe and why x86 never showed it.
#
# THERE IS NO KNOWN-GAP ROW LEFT, so the thing that keeps this from being an
# all-PASS check that compares nothing is a real NEGATIVE CONTROL: one extra
# build with SOURCE_DATE_EPOCH UNSET, which must differ from the pinned ones.
# Without it, "identical" would be equally consistent with a comparison that
# never looked.
#
# Not in tests/run-all.sh on purpose: five container builds, minutes each.
# MANUAL_TESTING.md carries the invocation.
#
# Usage: openbios-check-reproducible.sh <lab-dir>
set -uo pipefail

_VERDICT=0
note() { printf '  - %s\n' "$*" >&2; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: openbios-check-reproducible.sh exited early (rc=%d) — no verdict was printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT
for sig in TERM INT HUP; do
    # shellcheck disable=SC2064  # $sig must expand now, at trap-install time
    trap "printf 'FAIL: openbios-check-reproducible.sh killed by SIG%s\n' $sig >&2; exit $((128 + $(kill -l "$sig")))" "$sig"
done

LAB="${1:-}"
[[ -n "$LAB" && -x "$LAB/build-openbios.sh" ]] \
    || fail "usage: openbios-check-reproducible.sh <lab-dir>  (needs <lab-dir>/build-openbios.sh)"
command -v podman >/dev/null || skip "podman is not installed — this needs the lab's build box, and an unbuilt tree is an UNKNOWN, not a pass"

# A fixed instant, so the stamp is a constant rather than a second variable.
export SOURCE_DATE_EPOCH=1700000000
WANT_STAMP="$(LC_ALL=C TZ=UTC date -u -d "@$SOURCE_DATE_EPOCH" +'%b %e %Y %H:%M')"
WORK="$(mktemp -d)"

# arch : artifacts : expectation
ROWS=(
    "x86:openbios-x86.dict openbios-builtin.elf openbios.multiboot:same"
    "amd64:openbios-amd64.dict openbios-builtin.elf32 openbios.multiboot:same"
)
# The arch the negative control is run on. One extra build; x86 is the cheaper.
CTL_ARCH=x86
CTL_ART=openbios-x86.dict

PROBLEMS=""
CTL_FIRED=0
for row in "${ROWS[@]}"; do
    arch="${row%%:*}"; rest="${row#*:}"
    arts="${rest%%:*}"; want="${rest##*:}"
    for pass_n in 1 2; do
        if ! ( cd "$LAB" && ./build-openbios.sh "$arch" ) >"$WORK/build-$arch-$pass_n.log" 2>&1; then
            PROBLEMS+="$arch: build $pass_n failed — see $WORK/build-$arch-$pass_n.log"$'\n'
            continue 2
        fi
        mkdir -p "$WORK/$arch-$pass_n"
        for a in $arts; do
            cp "$HOME/openbios-lab/openbios/obj-$arch/$a" "$WORK/$arch-$pass_n/" 2>/dev/null \
                || PROBLEMS+="$arch: build $pass_n produced no $a"$'\n'
        done
    done

    # THE MECHANISM CONTROL: the stamp in the dictionary must be the one
    # SOURCE_DATE_EPOCH names. Without this, "identical" could mean the epoch was
    # ignored and both builds simply landed in the same minute.
    dict="$(echo $arts | tr ' ' '\n' | grep '\.dict$' | head -1)"
    got_stamp="$(strings -a "$WORK/$arch-1/$dict" 2>/dev/null | grep -m1 -E '^[A-Z][a-z]{2} [ 0-9]{2} 20[0-9]{2} [0-9]{2}:[0-9]{2}$')"
    if [[ "$got_stamp" != "$WANT_STAMP" ]]; then
        PROBLEMS+="$arch: the dictionary is stamped '${got_stamp:-nothing}' where SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH names '$WANT_STAMP' — the build ignored it, so any comparison below says nothing about reproducibility"$'\n'
        continue
    fi

    ident=1; diffs=""
    for a in $arts; do
        if ! cmp -s "$WORK/$arch-1/$a" "$WORK/$arch-2/$a"; then
            ident=0
            diffs+="$a($(cmp -l "$WORK/$arch-1/$a" "$WORK/$arch-2/$a" | grep -c .) bytes) "
        fi
    done

    if [[ "$want" == same ]]; then
        (( ident == 1 )) \
            || PROBLEMS+="$arch: two builds of one tree with the date pinned are NOT identical: $diffs— a second source of non-determinism has appeared beside the build date"$'\n'
        (( ident == 1 )) && note "$arch: byte-identical across two builds, stamped '$WANT_STAMP' ($(echo $arts | wc -w) artifacts)"
    fi
done

# ── THE NEGATIVE CONTROL. Everything above says "identical"; this is what makes
# that a measurement. One build with the epoch UNSET must differ from the pinned
# one -- if it does not, either the comparison is broken or SOURCE_DATE_EPOCH is
# not the thing doing the work.
if [[ -z "$PROBLEMS" ]]; then
    if ( cd "$LAB" && env -u SOURCE_DATE_EPOCH ./build-openbios.sh "$CTL_ARCH" ) \
            >"$WORK/build-ctl.log" 2>&1; then
        if cmp -s "$WORK/$CTL_ARCH-1/$CTL_ART" "$HOME/openbios-lab/openbios/obj-$CTL_ARCH/$CTL_ART"; then
            PROBLEMS+="the negative control did NOT fire: a build with SOURCE_DATE_EPOCH UNSET produced the same $CTL_ART as the pinned one, so 'byte-identical' above is consistent with a comparison that never looked"$'\n'
        else
            CTL_FIRED=1
            note "control: with SOURCE_DATE_EPOCH unset, $CTL_ARCH's $CTL_ART differs from the pinned build ($(cmp -l "$WORK/$CTL_ARCH-1/$CTL_ART" "$HOME/openbios-lab/openbios/obj-$CTL_ARCH/$CTL_ART" | grep -c .) bytes) — so the identity above is the variable's doing"
        fi
    else
        PROBLEMS+="the negative control build failed — see $WORK/build-ctl.log"$'\n'
    fi
fi

if [[ -n "$PROBLEMS" ]]; then
    while read -r p; do [[ -n "$p" ]] && note "$p"; done <<<"$PROBLEMS"
    fail "$(grep -c . <<<"$PROBLEMS") reproducibility problem(s) — see the lines above"
fi
(( CTL_FIRED == 1 )) \
    || fail "the negative control never fired — an all-PASS reproducibility check and one that compares nothing print the same thing, so this refuses to be green without watching a difference it can see"
pass "TODO 17.5 measured rather than asserted: with SOURCE_DATE_EPOCH pinned — and each dictionary stamped '$WANT_STAMP', which proves the build honoured it rather than two builds merely landing in the same minute — BOTH arches rebuild byte-identically, dictionaries and ELFs alike; the build date was one cause and a host-arena pointer baked into the amd64 image by the bootstrap was the other, and both are closed; and the identity is a measurement rather than an empty comparison because a build with the variable UNSET is watched to differ in the same run"
