#!/usr/bin/env bash
# smoke-client.sh [ppc|x86] [program] — one verdict that the OpenBIOS client
# interface runs our C client. program defaults to "hello" (see clib/*.c for
# the ladder: hello, memtest, edit, …). ppc is the track that works today: the
# STOCK qemu-system-ppc firmware already wires the client interface, so our
# cross-compiled client is loaded from a CD, entered via `boot`, and driven over
# the console — every line a firmware read/write service call.
#
#   ppc: build (if needed) <program>-ppc → a plain ISO9660 CD → boot cd:\NAME.;1
#        → drive it and expect the program's success marker.
#
# (x86 gets its own verdict once the firmware is revived — see POC-4.)
# Exit: 0 PASS / 1 FAIL / 77 SKIP.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OPENBIOS_CLIENTS_WORKDIR:-$HOME/openbios-clients-lab}"
FLAVOR="${1:-ppc}"
PROG="${2:-hello}"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
ACCEL="$([[ -w /dev/kvm ]] && echo kvm || echo tcg)"

trap 'rc=$?; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: test exited early (rc=$rc)"' EXIT

case "$FLAVOR" in
  ppc)
    command -v python3          >/dev/null || skip "python3 not installed"
    command -v qemu-system-ppc  >/dev/null || skip "qemu-system-ppc not installed"
    command -v genisoimage      >/dev/null || skip "genisoimage not installed"
    [[ -f "$HERE/clib/$PROG.c" ]] || skip "no such client program: clib/$PROG.c"

    CLIENT="$WORKDIR/$PROG-ppc"
    if [[ ! -f "$CLIENT" ]]; then
        note "no $CLIENT yet — building it"
        ( cd "$HERE" && ./build-client.sh ppc "$PROG" ) >/dev/null 2>&1 \
            || skip "could not build $PROG-ppc (need podman + the client build box)"
    fi
    [[ -f "$CLIENT" ]] || fail "$PROG-ppc missing after build"

    # Plain ISO9660 (NO RockRidge — it crashes OpenBIOS's dir); the ".;1"
    # version suffix on the name is mandatory at the prompt.
    NAME="$(echo "$PROG" | tr '[:lower:]' '[:upper:]')"
    ISO="$WORKDIR/$PROG-ppc.iso"; STAGE="$WORKDIR/.isoroot-$PROG"
    rm -rf "$STAGE" "$ISO"; mkdir -p "$STAGE"; cp "$CLIENT" "$STAGE/$NAME"
    genisoimage -quiet -o "$ISO" -V CLIENT "$STAGE" || fail "genisoimage failed"

    # Per-program: the success MARKER, the human phrase, a timeout, and the drive
    # steps between `boot` and the marker (interactive programs type keystrokes).
    BOOT="boot cd:\\\\$NAME.;1\r"
    case "$PROG" in
      hello)
        MARKER="Hello world!";  WHAT="answered Hello world!"; TMO=90
        STEPS=(--send "$BOOT" --expect "$MARKER") ;;
      memtest)
        MARKER="memtest: PASS"; WHAT="ran the RAM tester to a clean PASS"; TMO=140
        STEPS=(--send "$BOOT" --expect "$MARKER") ;;
      edit)
        # Interactive: type "hellX", Backspace (\x7f) the X, "o", then Ctrl-X (\x18).
        MARKER="edit: wrote 5 chars: hello"
        WHAT="ran a tiny interactive editor (typed, backspaced, Ctrl-X saved)"; TMO=90
        STEPS=(--send "$BOOT" --expect "Backspace edits"
               --send 'hellX' --send '\x7f' --send 'o' --expect 'o'
               --send '\x18' --expect "$MARKER") ;;
      emacs)
        # MicroEMACS-style, multi-line: type MEOW, Enter (split the line), PURR
        # on the new second line, then C-x C-c (\x18 \x03). The buffer dump on
        # exit must show both a bare "| MEOW" line and a "PURR" line — proof the
        # newline split landed (the multi-line op edit.c could not do).
        MARKER="emacs:"
        WHAT="ran a MicroEMACS-style multi-line editor (typed, split a line with Enter, C-x C-c saved-and-exited)"; TMO=120
        STEPS=(--send "$BOOT" --expect "clib-emacs"
               --send 'MEOW' --send '\r' --send 'PURR'
               --send '\x18' --send '\x03' --expect "$MARKER") ;;
      *)
        MARKER="EXIT"; WHAT="ran and exited via the client interface"; TMO=90
        STEPS=(--send "$BOOT" --expect "$MARKER") ;;
    esac

    LOG="$WORKDIR/smoke-client-ppc-$PROG.log"; rm -f "$LOG"
    note "booting stock qemu-system-ppc + our $PROG CD, driving boot cd:\\$NAME.;1 → $LOG"
    # ppc console input needs a real terminal, not a socket → the pty driver.
    python3 "$REPO/tools/drive-pty-repl.py" "$LOG" --timeout "$TMO" \
        --expect "0 > " "${STEPS[@]}" \
        -- qemu-system-ppc -M mac99 -m 256 -cdrom "$ISO" -nographic -vga none
    RC=$?
    # A program that entered but reported its OWN failure (e.g. memtest: FAIL)
    # is a real, specific defect — surface it, don't just time out.
    if grep -aq "memtest: FAIL" "$LOG"; then
        fail "REGRESSION: memtest reported memory errors on emulated RAM — clib claim/verify path broke (see $LOG)"
    fi
    [[ $RC -eq 0 ]] || fail "$PROG did not reach its success marker '$MARKER' (rc=$RC) — see $LOG"
    grep -aq "$MARKER" "$LOG" || fail "REGRESSION: firmware entered $PROG but no '$MARKER' — client interface path broke"
    if [[ "$PROG" == emacs ]]; then
        # The exit dump must show MEOW on its OWN line and PURR on the next —
        # i.e. Enter really SPLIT the line into two (multi-line editing works).
        grep -aqE '^\| MEOW[[:space:]]*$' "$LOG" || fail "REGRESSION: emacs buffer dump has no bare '| MEOW' line — the Enter line-split did not land (see $LOG)"
        grep -aq '| PURR'   "$LOG" || fail "REGRESSION: emacs buffer dump has no 'PURR' — typing on the split-off second line did not land (see $LOG)"
    fi
    pass "OpenBIOS-ppc loaded our C client '$PROG' and it $WHAT over the IEEE 1275 client interface" ;;

  x86)
    command -v python3             >/dev/null || skip "python3 not installed"
    command -v qemu-system-x86_64  >/dev/null || skip "qemu-system-x86_64 not installed"
    command -v genisoimage         >/dev/null || skip "genisoimage not installed"
    [[ -f "$HERE/clib/$PROG.c" ]] || skip "no such client program: clib/$PROG.c"

    # Unlike ppc, x86 needs the REVIVED firmware (POC-4) — stock OpenBIOS-x86
    # cannot load or enter a client at all.
    FW="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}/openbios/obj-x86"
    if [[ ! -f "$FW/openbios.multiboot" || ! -f "$FW/openbios.dict" ]]; then
        skip "no revived OpenBIOS-x86 at $FW — run ./build-firmware-x86.sh first"
    fi

    CLIENT="$WORKDIR/$PROG-x86"
    if [[ ! -f "$CLIENT" ]]; then
        note "no $CLIENT yet — building it"
        ( cd "$HERE" && ./build-client.sh x86 "$PROG" ) >/dev/null 2>&1 \
            || skip "could not build $PROG-x86 (need podman + the client build box)"
    fi
    [[ -f "$CLIENT" ]] || fail "$PROG-x86 missing after build"

    # x86 takes the RockRidge-lowercased name (genisoimage -r), so the path at
    # the prompt is the plain lowercase one — no ".;1" suffix as on ppc.
    ISO="$WORKDIR/$PROG-x86.iso"; STAGE="$WORKDIR/.isoroot-x86-$PROG"
    rm -rf "$STAGE" "$ISO"; mkdir -p "$STAGE"; cp "$CLIENT" "$STAGE/$PROG"
    genisoimage -quiet -r -o "$ISO" -V CLIENT "$STAGE" || fail "genisoimage failed"

    # x86 has no `boot cd:` shortcut for a client: load it, then go.
    # shellcheck disable=SC2016  # `$load` is the Forth word, not a shell var
    LOAD='" /ide@1/cdrom@0:\x5c'"$PROG"'" $load\r'
    case "$PROG" in
      hello)
        MARKER="Hello world!";  WHAT="answered Hello world!"; TMO=150
        STEPS=(--send "$LOAD" --expect "ok" --send 'go\r' --expect "$MARKER") ;;
      memtest)
        MARKER="memtest: PASS"; WHAT="ran the RAM tester to a clean PASS"; TMO=260
        STEPS=(--send "$LOAD" --expect "ok" --send 'go\r' --expect "$MARKER") ;;
      edit)
        MARKER="edit: wrote 5 chars: hello"
        WHAT="ran a tiny interactive editor (typed, backspaced, Ctrl-X saved)"; TMO=180
        STEPS=(--send "$LOAD" --expect "ok" --send 'go\r' --expect "Backspace edits"
               --send 'hellX' --send '\x7f' --send 'o' --expect 'o'
               --send '\x18' --expect "$MARKER") ;;
      emacs)
        # Same multi-line drive as ppc — see the ppc branch for the rationale.
        MARKER="emacs:"
        WHAT="ran a MicroEMACS-style multi-line editor (typed, split a line with Enter, C-x C-c saved-and-exited)"; TMO=280
        STEPS=(--send "$LOAD" --expect "ok" --send 'go\r' --expect "clib-emacs"
               --send 'MEOW' --send '\r' --send 'PURR'
               --send '\x18' --send '\x03' --expect "$MARKER") ;;
      *)
        MARKER="EXIT"; WHAT="ran and exited via the client interface"; TMO=150
        STEPS=(--send "$LOAD" --expect "ok" --send 'go\r' --expect "$MARKER") ;;
    esac

    LOG="$WORKDIR/smoke-client-x86-$PROG.log"; rm -f "$LOG"
    note "booting revived OpenBIOS-x86 + our $PROG CD, driving \$load + go → $LOG"
    # --echo-gate: the firmware prompt has no flow control, and the load line is
    # long enough to be dropped without it (see CLAUDE.md / POC-4).
    python3 "$REPO/tools/drive-pty-repl.py" "$LOG" --timeout "$TMO" --echo-gate \
        --expect "0 > " "${STEPS[@]}" \
        -- qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 \
           -kernel "$FW/openbios.multiboot" -initrd "$FW/openbios.dict" \
           -cdrom "$ISO" -display none -serial mon:stdio -no-reboot
    RC=$?
    if grep -aq "memtest: FAIL" "$LOG"; then
        fail "REGRESSION: memtest reported memory errors on emulated RAM — clib claim/verify path or the x86 cif-claim broke (see $LOG)"
    fi
    [[ $RC -eq 0 ]] || fail "$PROG did not reach its success marker '$MARKER' (rc=$RC) — see $LOG"
    grep -aq "$MARKER" "$LOG" || fail "REGRESSION: firmware entered $PROG but no '$MARKER' — client interface path broke"
    if [[ "$PROG" == emacs ]]; then
        grep -aqE '^\| MEOW[[:space:]]*$' "$LOG" || fail "REGRESSION: emacs buffer dump has no bare '| MEOW' line — the Enter line-split did not land (see $LOG)"
        grep -aq '| PURR'   "$LOG" || fail "REGRESSION: emacs buffer dump has no 'PURR' — typing on the split-off second line did not land (see $LOG)"
    fi
    pass "revived OpenBIOS-x86 loaded our C client '$PROG' and it $WHAT over the IEEE 1275 client interface" ;;
  *) echo "usage: $0 [ppc|x86] [program]" >&2; exit 1 ;;
esac
