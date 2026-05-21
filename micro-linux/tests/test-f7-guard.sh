#!/usr/bin/env bash
# AUDIT F7: safe_rm must refuse anything that isn't squarely inside out/.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
source "$MLBUILD"
set +e

# refusal cases run in a subshell so safe_rm's die() can't exit the test
refuse() { local lbl="$1"; shift; ( "$@" ) >/dev/null 2>&1 && fail "$lbl: expected refusal, but it succeeded" || note "$lbl refused"; }

refuse "refuse /"              safe_rm "/"
refuse "refuse \$HOME"         safe_rm "$HOME"
refuse "refuse repo root"      safe_rm "$REPO_ROOT"
refuse "refuse micro-linux/"   safe_rm "$SCRIPT_DIR"
refuse "refuse outside out/"   safe_rm "/tmp"
refuse "refuse empty arg"      safe_rm ""

mkdir -p "$OUT_DIR"

# a symlink under out/ (target inside out/) must still be refused (-L guard)
mkdir -p "$OUT_DIR/_t_real_$$"
ln -sfn "$OUT_DIR/_t_real_$$" "$OUT_DIR/_t_link_$$"
refuse "refuse symlink under out/" safe_rm "$OUT_DIR/_t_link_$$"
rm -f "$OUT_DIR/_t_link_$$"; rmdir "$OUT_DIR/_t_real_$$" 2>/dev/null || rm -rf "$OUT_DIR/_t_real_$$"

# a real dir squarely under out/ must be removed
d="$OUT_DIR/_t_guard_$$"; mkdir -p "$d/sub"; : > "$d/f"
( safe_rm "$d" ) >/dev/null 2>&1
[[ ! -e "$d" ]] || { rm -rf "$d"; fail "safe_rm should have removed $d"; }
note "removes a real dir squarely under out/"

pass "F7 destructive-op guard OK"
