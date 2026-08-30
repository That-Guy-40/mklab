#!/usr/bin/env bash
# openbios-pin-check.sh — has upstream moved past the pin in build-openbios.sh?
#
# The clone is pinned to exact commits (see build-openbios.sh) so that every
# patch in patches/ is a diff against a tree that does not move under them.
# A pin that nobody looks at is a pin that silently ages, so this asks the
# question on a schedule instead: it compares the pinned SHAs against the
# remotes' current HEADs and says which way they differ.
#
# IT DOES NOT BUMP ANYTHING. Moving the pin means re-reading the whole series and
# re-running every track on three arches; that is a decision, and this exists so
# that it is a decision someone makes rather than a surprise mid-build.
#
# READS THE PINS OUT OF build-openbios.sh rather than carrying its own copy — a
# second copy of a SHA is a cache of the first, and would go stale in exactly the
# situation this tool exists to detect.
#
# Exit: 0 pin is current / 1 upstream has moved / 77 cannot reach the remotes.
set -uo pipefail

_VERDICT=0
note() { printf '  - %s\n' "$*" >&2; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
# shellcheck disable=SC2154  # rc IS assigned, by the `rc=$?` at the start of this same
# single-quoted trap body; shellcheck analyses the string without carrying the assignment
# into the uses that follow it.
trap 'rc=$?; if (( rc != 0 && rc != 1 && rc != 77 )) && (( _VERDICT == 0 )); then printf "FAIL: openbios-pin-check.sh exited early (rc=%d)\n" "$rc" >&2; fi' EXIT

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/../examples/openbios-the-rival-that-shipped/build-openbios.sh"
[[ -f "$BUILD" ]] || fail "cannot find build-openbios.sh at $BUILD — the pins live there and this tool has no copy of its own"

pin_of() { sed -n "s/^$1=\\([0-9a-f]\\{40\\}\\)\$/\\1/p" "$BUILD" | head -1; }

declare -A REMOTE=(
    [OPENBIOS_PIN]=https://github.com/openbios/openbios.git
    [FCODE_UTILS_PIN]=https://github.com/openbios/fcode-utils.git
)

moved=0 checked=0
for var in OPENBIOS_PIN FCODE_UTILS_PIN; do
    pinned="$(pin_of "$var")"
    [[ -n "$pinned" ]] || fail "$var is not a 40-character SHA in build-openbios.sh — either the pin was removed (the build is tracking HEAD again) or its shape changed and this check is reading nothing"
    url="${REMOTE[$var]}"
    if ! head="$(timeout 60 git ls-remote "$url" HEAD 2>/dev/null | awk '{print $1}')" || [[ -z "$head" ]]; then
        skip "cannot reach $url — the pin is unchecked, which is an UNKNOWN and not a pass"
    fi
    checked=$((checked + 1))
    if [[ "$head" == "$pinned" ]]; then
        note "$var: ${pinned:0:7} is still the remote HEAD"
    else
        moved=$((moved + 1))
        note "$var: pinned ${pinned:0:7}, remote HEAD is now ${head:0:7} — $url"
    fi
done

(( checked == 2 )) || fail "only $checked of 2 pins were compared, so a green result would cover less than it claims"
if (( moved > 0 )); then
    fail "$moved of 2 upstream repositories have moved past the pin. Nothing is broken — the build still uses the pinned commits. Bumping is a decision: re-read the patches in examples/openbios-the-rival-that-shipped/patches/ and re-run every smoke track on x86, amd64 and ppc before changing the SHAs."
fi
pass "both pins are still the remote HEAD, so the tree the patches were written against is also the tree upstream is on"
