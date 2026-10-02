#!/usr/bin/env bash
# test-ttydrive.sh — prove tools/ttydrive actually drives an interactive program
# and, crucially, a NESTED tmux multi-pane TUI: type into it, address a specific
# pane, read the composed screen, and collect the exit status.
#
# Host-only: no QEMU, no root, no network. ttydrive runs each program in its own
# private tmux server and is the headless instrument for driving + grading a
# tmux-collated TUI — which is exactly the shape of pacme (GNU poke's acme UI,
# "small C programs collated by tmux"), the pacme lab's deferred Spike 3-full.
# This test is that capability's proof: if ttydrive can address two panes of a
# nested tmux independently and read both from one capture, it can drive pacme.
#
# tools/ttydrive is vendored byte-exact from the socwrap project
# (https://github.com/That-Guy-40/socwrap, tools/ttydrive 1.0.0) — its own
# header carries the attribution; `ttydrive -V` must print that version.
#
# One verdict, per house rule. PASS requires BOTH halves: the REPL drive
# (type/wait/screen/exit-status) and the nested-tmux multi-pane drive+capture.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TTYDRIVE="$HERE/../ttydrive"
INNER_SOCK="ttydrive-selftest-$$"   # the nested tmux's own server socket name

pass() { printf 'PASS: %s\n' "$*"; exit 0; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
note() { printf '  - %s\n' "$*"; }

command -v tmux    >/dev/null || skip "tmux not installed (ttydrive needs tmux 3.0+)"
command -v python3 >/dev/null || skip "python3 not installed (the REPL subject)"
[[ -x "$TTYDRIVE" ]] || skip "tools/ttydrive not found or not executable"
(( BASH_VERSINFO[0] >= 4 )) || skip "ttydrive needs bash 4+ (have ${BASH_VERSION})"

TTYDRIVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ttydrive-test.XXXXXX")"
export TTYDRIVE_DIR
T=("$TTYDRIVE")
cleanup() {
    "${T[@]}" stop --all >/dev/null 2>&1 || true
    tmux -L "$INNER_SOCK" kill-server >/dev/null 2>&1 || true
    rm -rf "$TTYDRIVE_DIR"
}
trap cleanup EXIT   # tools/tests is .harness-net-exempt; each test owns its cleanup

# the vendored tool must be the known version (catches a drifted/truncated copy)
ver="$("${T[@]}" -V 2>&1 || true)"
[[ "$ver" == "ttydrive 1.0.0" ]] || fail "ttydrive -V printed '$ver', not the vendored 'ttydrive 1.0.0' — the copy drifted"

# ── Part A: drive a Python REPL (the tool's own documented example) ─────────────
"${T[@]}" start py -- python3 -q || fail "could not start the python REPL session"
"${T[@]}" wait py '^>>>$' -t 15 || fail "the REPL prompt never appeared"
"${T[@]}" type py 'print(6 * 7)'; "${T[@]}" keys py Enter
"${T[@]}" wait py '^42$' -t 15 || { "${T[@]}" screen py >&2; fail "typing into the REPL did not yield 42 — input did not reach the program"; }
"${T[@]}" keys py C-d
st="$("${T[@]}" wait-exit py -t 15)"
[[ "$st" == "0" ]] || fail "the REPL exited with '$st', not 0 after Ctrl-D — exit status not collected faithfully"
"${T[@]}" stop py >/dev/null 2>&1
note "REPL drive: typed 6*7, read 42 off the screen, Ctrl-D → exit status 0"

# ── Part B: drive a NESTED tmux multi-pane TUI (pacme's shape) ──────────────────
# the inner tmux runs on its OWN server socket (-L), the same clean nesting pacme
# uses; ttydrive sees it as one program filling the terminal.
A="PANEMARK_A_${RANDOM}"; B="PANEMARK_B_${RANDOM}"
"${T[@]}" start ui -s 90x24 -- tmux -L "$INNER_SOCK" new-session -A -s demo \
    || fail "could not start the nested tmux session"
"${T[@]}" wait ui '\$' -t 15 >/dev/null || fail "the nested tmux's shell prompt never appeared"
"${T[@]}" keys ui C-b '%'                 # split the window vertically (tmux prefix is C-b)
sleep 0.5
"${T[@]}" type ui "echo $B"; "${T[@]}" keys ui Enter    # the new (right) pane is active
"${T[@]}" keys ui C-b Left; sleep 0.3                   # move to the left pane
"${T[@]}" type ui "echo $A"; "${T[@]}" keys ui Enter
# NOT anchored: in a split, each captured line carries BOTH panes separated by a
# divider (e.g. "PANEMARK_A … │ … PANEMARK_B"), so ^MARKER$ can never match; the
# marker is unique, so a substring wait is the right question here.
"${T[@]}" wait ui "$A" -t 15 >/dev/null || { "${T[@]}" screen ui >&2; fail "left-pane output never appeared — a split pane was not addressable"; }
scr="$("${T[@]}" screen ui)"
grep -q "$A" <<<"$scr" || { printf '%s\n' "$scr" >&2; fail "the left pane's marker ($A) is not in the captured screen"; }
grep -q "$B" <<<"$scr" || { printf '%s\n' "$scr" >&2; fail "the right pane's marker ($B) is not in the captured screen"; }
# an independent confirmation that two panes really exist (robust to divider glyph/locale)
npanes="$(tmux -L "$INNER_SOCK" list-panes -t demo 2>/dev/null | wc -l | tr -d ' ')"
[[ "$npanes" == "2" ]] || fail "the nested tmux reports $npanes panes, not 2 — the split did not take"
if grep -qE '│|\|' <<<"$scr"; then note "a vertical pane divider is visible in the capture"; fi
note "nested-tmux drive: addressed 2 panes independently (left=$A right=$B), both read from one capture — pacme's TUI shape"

pass "tools/ttydrive 1.0.0 drives an interactive program (python REPL: typed 6*7 → read 42 → exit 0) AND a NESTED tmux multi-pane TUI (two panes addressed independently and both read from a single screen capture) — the headless instrument the pacme lab's Spike 3-full (a tmux-collated acme UI) needs to drive and grade"
