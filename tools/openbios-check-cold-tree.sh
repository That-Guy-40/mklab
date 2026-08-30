#!/usr/bin/env bash
# openbios-check-cold-tree.sh — TODO §17.5's last sentence, measured.
#
# §17.5 closed byte-reproducibility with openbios-check-reproducible.sh, which
# asks "does THIS tree rebuild to the same bytes?" and answers it on both
# arches. It then wrote down a second, larger claim and left it unmeasured:
#
#     "The cold tree and the dev tree build identical bytes" is now a claim this
#     lab CAN make, on both arches, with SOURCE_DATE_EPOCH set.
#
# CAN MAKE IS NOT MEASURED. Nobody had built the cold tree and compared. That
# sentence is the shape this lab exists to find -- a present-tense claim nothing
# derives -- and it sat inside the section about records that outlive their
# subject. So this builds it.
#
# WHAT IS ACTUALLY BEING ASKED. The lab's tree is not stored: it is DEFINED as
# the pinned upstream commit plus patches/TESTED-TREE.patch. The dev tree is a
# working copy that has been patched, unpatched, rebuilt and edited by hand for
# weeks. If the definition and the working copy have drifted apart, every
# measurement this lab has published describes a tree nobody else can obtain --
# and the drift is silent, because both trees build and both boot.
#
# So: clone cold at the pin, apply the record, build, and compare BOTH halves.
#   * SOURCE identity -- every file, sha256, cold vs dev. This is the half that
#     catches an edit made in the working copy and never folded into a patch.
#   * ARTIFACT identity -- the dictionaries, the multiboot images and the
#     builtin ELF, byte for byte, on both arches. With SOURCE_DATE_EPOCH pinned
#     (patch 47) and the host-arena pointers scrubbed (patch 48), equal sources
#     must produce equal bytes; if they do not, a third source of
#     non-determinism has appeared and §17.5 is no longer closed.
#
# EXCLUDED FROM THE SOURCE COMPARISON, and not arbitrarily: .git (the archive
# tool excludes it for the same reason -- this is a question about a working
# tree, not its history), obj-* (build output), and config-host.mak, which
# switch-arch rewrites and is therefore a function of what was built last rather
# than of the tree. Same three exclusions as openbios-archive-tree.sh, on
# purpose: two definitions of "the tree" would be one too many.
#
# WHAT THE SIX ARTIFACTS DO AND DO NOT WITNESS, measured rather than assumed.
# openbios.multiboot is the loader and does NOT embed the dictionary: a tree
# carrying one extra Forth word built a BYTE-IDENTICAL multiboot on both arches,
# while openbios-<arch>.dict and openbios-builtin.elf both changed and both
# contained the new word. So a change to the FORTH sources is witnessed by four
# of the six files, and a change to the C sources by all six. "6/6 identical" is
# not six independent witnesses, and the note below says which is which rather
# than letting the ratio imply it.
#
# THE CONTROLS. An all-IDENTICAL run and a comparison that never looked print
# the same thing, so this refuses to pass without watching its comparator fire:
# a one-byte perturbation of a real artifact must compare unequal, and the two
# arches' dictionaries -- genuinely different files -- must differ. Neither is
# as strong as a rebuild control; the rebuild control lives in
# openbios-check-reproducible.sh and is not duplicated here.
#
# NOT IN tests/run-all.sh: a cold clone plus four container builds, minutes
# each. MANUAL_TESTING.md carries the invocation and the last measured result.
#
# Usage: openbios-check-cold-tree.sh <lab-dir> [--keep]
set -uo pipefail

_VERDICT=0
note() { printf '  - %s\n' "$*" >&2; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
WORK=""; KEEP=0
_on_exit() {
    local rc=$?
    if [[ -n "$WORK" ]]; then
        if (( KEEP == 1 )); then printf '  - kept: %s\n' "$WORK" >&2; else rm -rf -- "$WORK"; fi
    fi
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: openbios-check-cold-tree.sh exited early (rc=%d) — no verdict was printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT
for sig in TERM INT HUP; do
    # shellcheck disable=SC2064  # $sig must expand now, at trap-install time
    trap "printf 'FAIL: openbios-check-cold-tree.sh killed by SIG%s\n' $sig >&2; exit $((128 + $(kill -l "$sig")))" "$sig"
done

LAB=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        *)      LAB="$1"; shift ;;
    esac
done
[[ -n "$LAB" && -x "$LAB/build-openbios.sh" ]] \
    || fail "usage: openbios-check-cold-tree.sh <lab-dir> [--keep]  (needs <lab-dir>/build-openbios.sh)"
command -v podman >/dev/null \
    || skip "podman is not installed — this needs the lab's build box, and an unbuilt tree is an UNKNOWN, not a pass"

export SOURCE_DATE_EPOCH=1700000000
DEV="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
WORK="$(mktemp -d)"
COLD="$WORK/cold"
mkdir -p "$COLD"

# arch : artifacts
ROWS=(
    "x86:openbios-x86.dict openbios-builtin.elf openbios.multiboot"
    "amd64:openbios-amd64.dict openbios-builtin.elf32 openbios.multiboot"
)

build() { # build <workdir> <arch> <tag>
    OPENBIOS_WORKDIR="$1" "$LAB/build-openbios.sh" "$2" >"$WORK/build-$3-$2.log" 2>&1
}

PROBLEMS=""
for row in "${ROWS[@]}"; do
    arch="${row%%:*}"
    build "$COLD" "$arch" cold || PROBLEMS+="the COLD tree failed to build $arch — see $WORK/build-cold-$arch.log (kept only with --keep)"$'\n'
    build "$DEV"  "$arch" dev  || PROBLEMS+="the DEV tree failed to build $arch — see $WORK/build-dev-$arch.log (kept only with --keep)"$'\n'
done
[[ -z "$PROBLEMS" ]] || { while read -r p; do [[ -n "$p" ]] && note "$p"; done <<<"$PROBLEMS"; fail "a build failed, so nothing below was compared"; }

# ── SOURCE: is the definition the same files as the working copy?
digest_tree() { # digest_tree <root>
    ( cd "$1" && find . -type f \
        -not -path './.git/*' -not -path './obj-*' -not -name 'config-host.mak' \
        -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) 2>/dev/null
}
digest_tree "$COLD/openbios" >"$WORK/src-cold.txt"
digest_tree "$DEV/openbios"  >"$WORK/src-dev.txt"
NC="$(grep -c . <"$WORK/src-cold.txt" || true)"
ND="$(grep -c . <"$WORK/src-dev.txt"  || true)"
(( NC > 0 && ND > 0 )) \
    || fail "one of the trees digested to nothing (cold=$NC dev=$ND) — the comparison below would be empty, which is not the same as identical"
SRC_SAME=1
if diff -q "$WORK/src-cold.txt" "$WORK/src-dev.txt" >/dev/null; then
    note "source: $NC/$NC files sha256-identical — the pin plus TESTED-TREE.patch regenerates the working tree exactly"
else
    SRC_SAME=0
    # ONE file, not two entries: a changed file shows up as both a `<` and a
    # `>`, and reporting the raw line count says "2 differing entries" for a
    # single edited file. The control caught that on its first run.
    diff "$WORK/src-cold.txt" "$WORK/src-dev.txt" | grep '^[<>]' | awk '{print $NF}' | sort -u >"$WORK/src-differ.txt"
    n="$(grep -c . <"$WORK/src-differ.txt" || true)"
    PROBLEMS+="the COLD tree and the DEV tree are NOT the same source: $n file(s) differ (cold has $NC, dev has $ND) — an edit lives in the working copy that no patch records, so every result this lab publishes describes a tree nobody else can obtain: $(head -4 "$WORK/src-differ.txt" | tr '\n' ' ')"$'\n'
fi

# ── ARTIFACTS: equal sources must produce equal bytes.
NART=0
for row in "${ROWS[@]}"; do
    arch="${row%%:*}"; arts="${row#*:}"
    for a in $arts; do
        c="$COLD/openbios/obj-$arch/$a"; d="$DEV/openbios/obj-$arch/$a"
        if [[ ! -f "$c" || ! -f "$d" ]]; then
            PROBLEMS+="$arch/$a is missing from $([[ -f "$c" ]] || printf 'the COLD tree'; [[ -f "$d" ]] || printf ' the DEV tree') — a build that produced no artifact cannot be compared, and an absent file must not read as agreement"$'\n'
            continue
        fi
        NART=$((NART + 1))
        # THE DIAGNOSIS DEPENDS ON THE SOURCE HALF, and saying otherwise is how a
        # message becomes a liar. "A third source of non-determinism" is only the
        # reading when the sources were IDENTICAL; when they were not, the bytes
        # differ for the obvious reason and pointing at determinism would send a
        # reader hunting something that is not there. The control ran with an
        # unrecorded edit and printed the non-determinism sentence four times.
        if ! cmp -s "$c" "$d"; then
            # cmp -l writes "EOF on <file>" to stderr when the lengths differ;
            # that is not part of the count and must not reach the report.
            nb="$(cmp -l "$c" "$d" 2>/dev/null | grep -c . || true)"
            if (( SRC_SAME == 1 )); then
                PROBLEMS+="$arch/$a differs between the cold and dev trees by $nb byte(s) — the sources are IDENTICAL and SOURCE_DATE_EPOCH is pinned, so a third source of non-determinism has appeared beside the build date and the host-arena pointers, and TODO §17.5 is no longer closed"$'\n'
            else
                PROBLEMS+="$arch/$a differs between the cold and dev trees by $nb byte(s) — expected, given the source difference reported above; fold that edit into a patch and re-run before reading anything into these bytes"$'\n'
            fi
        fi
    done
done

# ── THE CONTROLS.
CTL=0
ctl_src="$COLD/openbios/obj-x86/openbios-x86.dict"
if [[ -f "$ctl_src" ]]; then
    cp "$ctl_src" "$WORK/perturbed.bin"
    printf '\xff' | dd of="$WORK/perturbed.bin" bs=1 seek=1024 count=1 conv=notrunc status=none
    if cmp -s "$WORK/perturbed.bin" "$DEV/openbios/obj-x86/openbios-x86.dict"; then
        PROBLEMS+="the comparator control did NOT fire: a one-byte perturbation compared EQUAL, so every 'identical' above is consistent with a comparison that never looked"$'\n'
    else
        CTL=$((CTL + 1))
    fi
    if cmp -s "$ctl_src" "$COLD/openbios/obj-amd64/openbios-amd64.dict"; then
        PROBLEMS+="the second control did NOT fire: the x86 and amd64 dictionaries compared EQUAL, which two different ports cannot be"$'\n'
    else
        CTL=$((CTL + 1))
    fi
else
    PROBLEMS+="no cold x86 dictionary to run the controls against — the checks above are unproven"$'\n'
fi

if [[ -n "$PROBLEMS" ]]; then
    while read -r p; do [[ -n "$p" ]] && note "$p"; done <<<"$PROBLEMS"
    fail "$(grep -c . <<<"$PROBLEMS") cold-tree problem(s) — see the lines above"
fi
(( CTL == 2 )) \
    || fail "only $CTL of 2 comparator controls fired — this refuses to report identity it has not watched itself able to deny"
note "controls: a one-byte perturbation compares unequal; the two arches' dictionaries differ"
note "reach: of the $NART artifacts, the two openbios.multiboot loaders do NOT embed the dictionary — a Forth-source change is witnessed by the .dict and openbios-builtin.elf only, a C-source change by all of them"
pass "TODO §17.5's last sentence measured rather than asserted: a COLD clone at the pin plus patches/TESTED-TREE.patch reproduces the dev tree exactly — $NC/$NC source files sha256-identical — and with SOURCE_DATE_EPOCH pinned the two trees build $NART/$NART artifacts byte-for-byte identical across x86 and amd64, so the tree this lab measures is the tree its record defines"
