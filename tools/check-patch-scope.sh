#!/usr/bin/env bash
# check-patch-scope.sh — a patch that leaves arch/{x86,amd64}/ must say which arches were tested.
#
# WHY. On 2026-08-25 this lab applied its first arch-neutral patch
# (15-forth-loader-divergence.patch, libopenbios/initprogram.c). That file is built
# UNCONDITIONALLY for every arch, and the lab builds ppc — but the ppc track was not run
# before the PR was opened. It passed when it was finally run, so nothing broke; the point
# is that nothing would have SAID so. The gap was caught by a human asking "are we sure we
# aren't polluting the ppc tree?", which is exactly the kind of catch that should not
# depend on someone thinking to ask.
#
# THE RULE. A patch whose diff touches any path outside arch/x86/, arch/amd64/,
# include/arch/{x86,amd64}/ and the two per-arch config files must carry a header line:
#
#     Arch-tested: x86 amd64 ppc
#
# naming every arch this lab can actually build and drive. Those three are not arbitrary:
# they are the tracks smoke-openbios.sh has (multiboot/dict-identity/nvram/... on x86,
# amd64* on amd64, ppc on ppc). sparc is NOT in the list because this lab cannot test it —
# a patch that reaches sparc is reported as an UNKNOWN below rather than being waved past.
#
# Patches predating the rule are exempt BY NAME AND WITH A REASON, not by a date cutoff:
# an exemption whose justification is "it is old" grows silently.
set -uo pipefail

_VERDICT=0
note() { printf '  - %s\n' "$*" >&2; }
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: check-patch-scope.sh exited early (rc=%d) — no verdict was printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT
for sig in TERM INT HUP; do
    trap "printf 'FAIL: check-patch-scope.sh killed by SIG%s\n' $sig >&2; exit \$((128 + \$(kill -l $sig)))" "$sig"
done

# The arches this lab can build AND drive. Keep in step with smoke-openbios.sh's tracks.
LAB_ARCHES=(x86 amd64 ppc)

# Paths a patch may touch without declaring anything: the two arch dirs this lab owns,
# and their own config files.
is_confined() {
    case "$1" in
        arch/x86/*|arch/amd64/*)                                   return 0 ;;
        # An arch's OWN header dir, added 2026-08-26 for patch 17. It is the same
        # blast radius as arch/<a>/ -- include/arch/amd64/io.h is compiled into
        # nothing but amd64 -- and the distinction that matters is one directory
        # away: include/drivers/, include/libopenbios/ and friends are SHARED, and
        # must-catch-5 below keeps them on the declaring side of the line.
        include/arch/x86/*|include/arch/amd64/*)                   return 0 ;;
        config/examples/x86_config.xml|config/examples/amd64_config.xml) return 0 ;;
        *)                                                         return 1 ;;
    esac
}

# Files touched by a patch: the +++ side, which is what actually gets written.
patch_paths() { grep -oE '^\+\+\+ b/[^ 	]+' "$1" | sed 's|^+++ b/||' | sort -u; }

# The declaration, if any.
# `.*`, NOT `[^\n]*`. In a POSIX ERE bracket expression a backslash is LITERAL, so
# `[^\n]` means "not a backslash and not the letter n" -- it truncated every
# Arch-tested: line at its first `n`, which is why `unix` read as ` u`. grep is
# line-oriented and `.` never matches a newline, so `.*` is the whole line and is
# what was meant. Same family as the `\t` that once ate every line ending in `t`;
# must-not-6 below is the fixture that keeps it fixed.
declared_arches() { grep -oiE '^Arch-tested:.*' "$1" | head -1 | cut -d: -f2- | tr 'A-Z' 'a-z'; }

# Verdict for one patch. Echoes a reason on failure, nothing on success.
classify() {
    local f="$1" shared decl missing a
    shared=""
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        is_confined "$p" || shared+="$p "
    done < <(patch_paths "$f")

    [[ -z "$shared" ]] && return 0          # confined to arch/{x86,amd64} — nothing to declare

    decl="$(declared_arches "$f")"
    if [[ -z "$decl" ]]; then
        echo "$(basename "$f"): touches shared path(s) [${shared% }] but has no 'Arch-tested:' line"
        return 1
    fi
    missing=""
    for a in "${LAB_ARCHES[@]}"; do
        grep -qw -- "$a" <<<"$decl" || missing+="$a "
    done
    if [[ -n "$missing" ]]; then
        echo "$(basename "$f"): touches shared path(s) [${shared% }] and its Arch-tested line omits [${missing% }] — this lab can build and drive those, so an untested one is an UNKNOWN, not a pass"
        return 1
    fi
    return 0
}

# ── §0 the checker proves itself on fixtures BEFORE it looks at a real patch ────────────
# A scan that matches nothing and a scan that is broken print the same green tick.
WORK="$(mktemp -d)"
mk() { printf '%s\n' "$2" > "$WORK/$1"; }

mk must-catch-1.patch 'Subject: [PATCH] touches libopenbios with no declaration
--- a/libopenbios/initprogram.c
+++ b/libopenbios/initprogram.c'
mk must-catch-2.patch 'Subject: [PATCH] declares only two of three
Arch-tested: x86 amd64
--- a/drivers/ide.c
+++ b/drivers/ide.c'
mk must-catch-3.patch 'Subject: [PATCH] forth/ is shared too
Arch-tested: amd64
--- a/forth/admin/nvram.fs
+++ b/forth/admin/nvram.fs'
mk must-catch-4.patch 'Subject: [PATCH] a shared path alongside a confined one still counts
Arch-tested: x86
--- a/arch/amd64/openbios.c
+++ b/arch/amd64/openbios.c
--- a/kernel/forth.c
+++ b/kernel/forth.c'

mk must-not-1.patch 'Subject: [PATCH] arch/amd64 only
--- a/arch/amd64/openbios.c
+++ b/arch/amd64/openbios.c'
mk must-not-2.patch 'Subject: [PATCH] both arch dirs this lab owns
--- a/arch/x86/openbios.c
+++ b/arch/x86/openbios.c
--- a/arch/amd64/openbios.c
+++ b/arch/amd64/openbios.c'
mk must-not-3.patch 'Subject: [PATCH] shared, and declares all three
Arch-tested: x86 amd64 ppc
--- a/libopenbios/initprogram.c
+++ b/libopenbios/initprogram.c'
mk must-not-6.patch 'Subject: [PATCH] shared, all three declared AFTER a word containing n
Arch-tested: none-of-the-below, actually x86 amd64 ppc
--- a/libopenbios/initprogram.c
+++ b/libopenbios/initprogram.c'
mk must-not-4.patch 'Subject: [PATCH] per-arch config files are confined
--- a/config/examples/amd64_config.xml
+++ b/config/examples/amd64_config.xml'
mk must-not-5.patch 'Subject: [PATCH] an arch owns its own include dir too
--- a/include/arch/amd64/io.h
+++ b/include/arch/amd64/io.h'

# The pair that makes the widening meaningful. Both live under include/; only one of
# them is an arch's own. If is_confined() is ever loosened to a bare include/arch or,
# worse, to include/, must-catch-5 fires.
mk must-catch-5.patch 'Subject: [PATCH] include/drivers is SHARED, one directory away
--- a/include/drivers/vga.h
+++ b/include/drivers/vga.h'
mk must-catch-6.patch 'Subject: [PATCH] another arch include dir is not ours to test
--- a/include/arch/ppc/io.h
+++ b/include/arch/ppc/io.h'

ctl_fail=()
for f in "$WORK"/must-catch-*.patch; do
    classify "$f" >/dev/null && ctl_fail+=("§0: $(basename "$f") was NOT caught")
done
for f in "$WORK"/must-not-*.patch; do
    classify "$f" >/dev/null || ctl_fail+=("§0: $(basename "$f") was caught but must not be")
done
if (( ${#ctl_fail[@]} )); then
    fail "$(printf 'the checker failed its own controls:'; printf '\n      %s' "${ctl_fail[@]}")"
fi
note "§0 controls: 6 must-catch, 5 must-not-catch — all 11 behaved"

# ── §1 the real patches ────────────────────────────────────────────────────────────────
(( $# )) || fail "usage: check-patch-scope.sh <patches-dir>"
DIR="$1"
[[ -d "$DIR" ]] || fail "not a directory: $DIR"

# Grandfathered BY NAME, each with the reason it is exempt. Adding a name here is a
# reviewable act; a date cutoff would not be.
declare -A EXEMPT=(
  [01-x86-revival.patch]="predates the rule (2026-07); the x86 revival, whose scope was the whole point and is described at length in its header"
  [05-x86-nvram-p1-ide-backing.patch]="predates the rule; drivers/ide.c reached for the NVRAM backing spikes"
  [07-x86-floppy-backing.patch]="predates the rule; drivers/floppy.c, same series"
  [08-amd64-spike1-trampoline.patch]="predates the rule; Spike 1 touched Makefile.target and libgcc to get amd64 linking at all"
  [12-amd64-spike3-boots-linux.patch]="predates the rule; forth/admin/nvram.fs gained the CONFIG_AMD64 block"
)

problems=(); checked=0; exempted=()
shopt -s nullglob
for f in "$DIR"/*.patch; do
    b="$(basename "$f")"
    if [[ -n "${EXEMPT[$b]:-}" ]]; then exempted+=("$b"); continue; fi
    checked=$((checked + 1))
    if ! reason="$(classify "$f")"; then problems+=("$reason"); fi
done
shopt -u nullglob

(( checked )) || fail "no patches examined in $DIR — a checker that looks at nothing prints the same tick as one that passes"

if (( ${#exempted[@]} )); then
    note "grandfathered by name (${#exempted[@]}): ${exempted[*]}"
fi

# sparc is reachable by any shared-path patch and this lab cannot drive it. Say so on
# every run rather than letting "all three named" read as "all arches covered".
note "NOT COVERED: sparc32/sparc64 build from these shared files and this lab has no track for them — an UNKNOWN on every shared patch, by construction"

if (( ${#problems[@]} )); then
    fail "$(printf '%d patch(es) leave arch/{x86,amd64} without saying what was tested:' "${#problems[@]}"; printf '\n      %s' "${problems[@]}")"
fi

pass "$checked patch(es) checked: every one that touches a path outside arch/{x86,amd64} names all of ${LAB_ARCHES[*]} as tested (12 self-controls fired first; ${#exempted[@]} grandfathered by name with reasons)"
