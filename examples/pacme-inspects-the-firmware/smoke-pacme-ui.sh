#!/usr/bin/env bash
# smoke-pacme-ui.sh — Spike 3-full: the INTERACTIVE acme UI, driven and GRADED
# headlessly. pacme (GNU poke's tmux-collated UI) shows a structured view of a
# firmware device tree, and that view is graded against the toolkit's reading of
# the same bytes — the UI is never trusted as its own oracle.
#
# This is the spike the lab deferred because "we do not verify a TUI headlessly."
# tools/ttydrive dissolves that: it drives a real tmux TUI one keystroke at a time
# and reads the composed screen, so the UI becomes a thing we can assert against.
#
# THE STACK (all host-side, no QEMU, no sudo; GPLv3 wall — pacme runs beside
# poked, never linked into the firmware):
#   * build pacme from source (build-pacme.sh) if not already built
#   * flatten OpenBIOS's own live device tree to a DTB with the hosted
#     openbios-unix + the dsl/fdt.fth toolkit (dt>fdt) — the Forth toolkit's own
#     bytes, the same way smoke-pacme-fdt.sh / -span.sh get theirs
#   * start `poked`; launch pacme under ttydrive; trigger Layout 2 (C-g F2 →
#     a plet-repl pane + a plet-out pane); type poke reads into the REPL; the
#     RESULT renders in the plet-out pane, which ttydrive reads off the screen
#
# THE GRADE — three readers of ONE live-flattened device tree agree:
#   (Forth) dsl/fdt.fth produced the DTB; (pickle) fdt.pk reads its header
#   headless; (UI) pacme's REPL reads magic + totalsize. The pacme UI's magic and
#   totalsize equal fdt.pk's, and the magic is the spec's 0xd00dfeed. The UI shows
#   what the toolkit shows, on the firmware's own bytes.
# CONTROL THAT BITES: the UI read one field over (offset 4, totalsize) does NOT
# read 0xd00dfeed — the UI's read is position-specific, not a lucky constant; and
# the plet-out pane must actually carry the value (asserted via ttydrive wait,
# not assumed).
#
# THE HONEST BOUNDARY (UNKNOWN != PASS): this drives and grades the UI's DATA
# PATH (REPL → poked → plet-out), headlessly. It does not grade pixel layout,
# colors, or human ergonomics — those a person judges interactively (the lab's
# MANUAL_TESTING shows the by-hand drive). What is claimed is exactly what is
# measured: the UI displays the toolkit's values for the firmware's bytes.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR (default ~/openbios-lab).
set -uo pipefail
usage() {
    cat <<'USAGE'
smoke-pacme-ui.sh   Spike 3-full: pacme's interactive tmux UI, driven + graded headlessly

Builds pacme from source (build-pacme.sh), flattens OpenBIOS's live device tree
to a DTB, launches pacme under tools/ttydrive, triggers the REPL+out layout,
reads the FDT magic + totalsize through the UI, and grades them equal to fdt.pk's
headless reading of the same bytes (magic == 0xd00dfeed). Control: the UI read one
field over is not the magic. SKIPs by name without poke/poked/tmux/ttydrive/the
unix firmware, or if a poked is already running on the shared socket.
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RIVAL="$(cd "$HERE/../openbios-the-rival-that-shipped" && pwd)"
DSL="$RIVAL/dsl"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
UB="$WORKDIR/openbios/obj-amd64/openbios-unix"; UD="$UB.dict"
TTYDRIVE="$REPO/tools/ttydrive"
SOCK="/tmp/poked-$(id -u).ipc"     # the path pacme's pokelets connect to (hard-coded in plet-*)

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
heq()  { [[ "$1" =~ ^[0-9a-fA-F]+$ && "$2" =~ ^[0-9a-fA-F]+$ ]] && (( 16#$1 == 16#$2 )); }
WD=""; POKED=""; MADE_SOCK=0; XDG=""
cleanup() {
    local rc=$?
    # pacme runs its OWN tmux server (a separate socket from ttydrive's), so it
    # OUTLIVES `ttydrive stop` — kill that server by its socket, not by pattern.
    [[ -n "$XDG" && -S "$XDG/pacme.ipc" ]] && tmux -S "$XDG/pacme.ipc" kill-server 2>/dev/null
    [[ -n "${TTYDRIVE_DIR:-}" ]] && "$TTYDRIVE" stop --all >/dev/null 2>&1
    [[ -n "$POKED" ]] && kill "$POKED" 2>/dev/null
    [[ "$MADE_SOCK" == 1 ]] && rm -f "$SOCK"
    [[ -n "${TTYDRIVE_DIR:-}" ]] && rm -rf "$TTYDRIVE_DIR"
    [[ -n "$XDG" ]] && rm -rf "$XDG"
    [[ -n "$WD" ]] && rm -rf "$WD"
    [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-pacme-ui.sh exited early (rc=$rc)"
}
trap cleanup EXIT

command -v poke  >/dev/null || skip "GNU poke not installed — run ./deps.sh"
command -v poked >/dev/null || skip "poked (the poke daemon) not installed — part of GNU poke"
command -v tmux  >/dev/null || skip "tmux not installed (pacme's screen manager)"
[[ -x "$TTYDRIVE" ]] || skip "tools/ttydrive not found — the headless TUI driver"
[[ -f "$UB" && -f "$UD" ]] || skip "no openbios-unix at $UB — run build-openbios.sh unix first"
[[ -f "$HERE/fdt.pk" ]] || fail "missing $HERE/fdt.pk"
for f in struct.fth contract.fth fdt.fth fdt-read.fth fdt-conform.fth; do [[ -f "$DSL/$f" ]] || fail "missing $DSL/$f"; done
# do not clobber a poked someone else is running on the shared per-uid socket
[[ -S "$SOCK" ]] && skip "a poked is already listening on $SOCK — this smoke needs its own; stop it and retry"

# ── build pacme from source (idempotent; SKIPs by name if a prereq is missing) ──
berr="$(mktemp)"; PREFIX="$("$HERE/build-pacme.sh" 2>"$berr")"; brc=$?
if [[ $brc -eq 77 ]]; then m="$(sed -n 's/^SKIP: //p;/MISSING/p' "$berr" | head -1)"; rm -f "$berr"; skip "pacme not built: ${m:-a prerequisite is missing (run ./build-pacme.sh)}"; fi
[[ $brc -eq 0 && -x "$PREFIX/bin/pacme" ]] || { tail -5 "$berr" >&2; rm -f "$berr"; fail "build-pacme.sh failed — run it directly to see why"; }
rm -f "$berr"
note "pacme: $PREFIX/bin/pacme (+ plet-repl, plet-out)"

WD="$(mktemp -d /tmp/pk.XXXXXX)"

# ── flatten OpenBIOS's live device tree to a DTB (the Forth toolkit's own bytes) ──
( cd "$WD" && { cat "$DSL/struct.fth" "$DSL/contract.fth" "$DSL/fdt.fth" "$DSL/fdt-read.fth" "$DSL/fdt-conform.fth"
  printf '%s\n' '/fdt-buf alloc-mem value fb' 'fb dt>fdt value flen' \
    'fb flen s" live.dtb" write-file ." WROTE" cr' 'bye'
  } | "$UB" "$UD" >"$WD/fw.log" 2>&1 )
[[ -s "$WD/live.dtb" ]] || { cat "$WD/fw.log" >&2; fail "openbios-unix did not flatten live.dtb"; }
DTB_SIZE=$(stat -c%s "$WD/live.dtb")
note "flattened the live device tree → live.dtb ($DTB_SIZE bytes) via dsl/fdt.fth dt>fdt"

# ── headless TOOLKIT reading of the same bytes (fdt.pk — the lab's pickle) ──
# open() INSIDE -c (a positional FILE opens only AFTER the -c run → "no IOS")
pkhdr() { POKE_LOAD_PATH="$HERE" poke --quiet -c 'load fdt;' -c \
  "var f = open(\"$WD/live.dtb\"); var h = FDT_Header @ 0#B; printf(\"%u32x %u32d\", h.magic, h.totalsize);" 2>/dev/null; }
read -r PK_MAGIC PK_TSIZE <<<"$(pkhdr)"
heq "$PK_MAGIC" d00dfeed || fail "fdt.pk read magic '$PK_MAGIC' (not d00dfeed) from live.dtb — the toolkit baseline is wrong (test bug, not a UI result)"
note "toolkit (fdt.pk headless): magic=$PK_MAGIC totalsize=$PK_TSIZE"

# ── start poked on the socket the pokelets expect ──
export TTYDRIVE_DIR; TTYDRIVE_DIR="$(mktemp -d /tmp/ttyd.XXXXXX)"
XDG="$(mktemp -d /tmp/pacme-xdg.XXXXXX)"
POKE_LOAD_PATH="$HERE" poked -S "$SOCK" >"$WD/poked.log" 2>&1 & POKED=$!
for _ in $(seq 1 30); do [[ -S "$SOCK" ]] && break; sleep 0.2; done
[[ -S "$SOCK" ]] && MADE_SOCK=1 || { cat "$WD/poked.log" >&2; fail "poked did not create its socket $SOCK"; }

# ── launch pacme under ttydrive, trigger Layout 2 (REPL + out panes) ──
# pacme's tmux launches the pokelets (plet-repl/-out) as bare commands, so
# $PREFIX/bin must be on the PATH the inner tmux inherits — pass it via -e.
"$TTYDRIVE" start ui -s 120x40 -e "XDG_RUNTIME_DIR=$XDG" -e "PATH=$PREFIX/bin:$PATH" -- "$PREFIX/bin/pacme" \
    || fail "ttydrive could not launch pacme"
"$TTYDRIVE" wait ui '\$' -t 15 >/dev/null || fail "pacme's tmux did not reach a shell prompt"
"$TTYDRIVE" keys ui C-g F2        # Layout 2: a plet-repl pane + a plet-out pane
"$TTYDRIVE" wait ui 'poke!#' -t 20 >/dev/null || { "$TTYDRIVE" screen ui >&2; fail "the plet-repl pane (#!poke!#) never appeared after C-g F2 (pokelets on PATH? poked up?)"; }
"$TTYDRIVE" settle ui -t 10 >/dev/null 2>&1   # let both panes finish drawing before typing

# ── drive the REPL; results render in the plet-out pane; read them off the screen ──
# ONE line, not five: plet-repl is readline-based, and firing several type+Enter
# in a row races readline when the machine is busy (measured: flaky across rapid
# runs). A single compound statement is one read, one poked eval, and all three
# printfs land in plet-out together. The control read (offset 4) rides along.
"$TTYDRIVE" type ui "var f = open(\"$WD/live.dtb\"); var _e = set_endian (ENDIAN_BIG); printf (\"UIMAGIC=%u32x\n\", uint<32> @ 0#B); printf (\"UITSIZE=%u32d\n\", uint<32> @ 4#B); printf (\"UIWRONG=%u32x\n\", uint<32> @ 4#B)"
"$TTYDRIVE" keys ui Enter
"$TTYDRIVE" wait ui 'UIWRONG=[0-9a-f]' -t 20 >/dev/null || { "$TTYDRIVE" screen ui --all >&2; fail "the UI never rendered the reads in the plet-out pane — the REPL→poked→out path did not carry a result"; }
"$TTYDRIVE" settle ui -t 10 >/dev/null 2>&1   # let the final line finish rendering
scr="$("$TTYDRIVE" screen ui --all)"
UI_MAGIC=$(grep -oE 'UIMAGIC=[0-9a-f]+' <<<"$scr" | head -1 | cut -d= -f2)
UI_TSIZE=$(grep -oE 'UITSIZE=[0-9]+'    <<<"$scr" | head -1 | cut -d= -f2)
UI_WRONG=$(grep -oE 'UIWRONG=[0-9a-f]+' <<<"$scr" | head -1 | cut -d= -f2)
[[ -n "$UI_MAGIC" && -n "$UI_TSIZE" && -n "$UI_WRONG" ]] || { printf '%s\n' "$scr" >&2; fail "could not read the UI's values from the plet-out pane"; }
note "pacme UI (plet-out pane): magic=$UI_MAGIC totalsize=$UI_TSIZE"

# ── grade: the UI agrees with the toolkit on the firmware's bytes ──
heq "$UI_MAGIC" d00dfeed || fail "the pacme UI showed magic '$UI_MAGIC', not the spec's d00dfeed"
heq "$UI_MAGIC" "$PK_MAGIC" || fail "UI magic ($UI_MAGIC) != fdt.pk's ($PK_MAGIC) on the same bytes — the UI and the toolkit disagree"
[[ "$UI_TSIZE" == "$PK_TSIZE" ]] || fail "UI totalsize ($UI_TSIZE) != fdt.pk's ($PK_TSIZE)"
[[ "$UI_TSIZE" == "$DTB_SIZE" ]] || note "note: totalsize $UI_TSIZE vs file size $DTB_SIZE (padding is allowed by the spec)"
note "grade: pacme UI == fdt.pk == 0xd00dfeed on magic, and == on totalsize ($UI_TSIZE) — three readers, one live-flattened device tree"

# ── control: the UI read one field over is NOT the magic ──
heq "$UI_WRONG" d00dfeed && fail "CONTROL did NOT bite: the UI read at offset 4 also showed d00dfeed — the UI read is not position-specific"
note "control: the UI read one field over (offset 4) is '$UI_WRONG', not the magic — the UI's read is position-specific"

pass "Spike 3-full: pacme's interactive tmux UI, driven headlessly by tools/ttydrive, displays the toolkit's values for OpenBIOS's own live-flattened device tree — the REPL-read magic ($UI_MAGIC) and totalsize ($UI_TSIZE) equal fdt.pk's headless reading and the spec's 0xd00dfeed, read straight off the plet-out pane; a read one field over is not the magic (position-specific control). The UI is graded against the Forth/pickle toolkit, not trusted — the deferred interactive-UI strand is now a measured one (its data path; human ergonomics stay a by-hand judgement). Host-side, GPLv3-walled"
