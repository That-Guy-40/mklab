#!/usr/bin/env bash
# smoke-habitat.sh [nvramrc|ladder|media|patch|autotrace|persist|console|all] [sparc32|ppc]
#   — one verdict per claim, on the architectures where Open Firmware shipped.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.
#
# ONE harness, two tracks: everything that differs lives in lib-habitat.sh.
# Both tracks run the STOCK OpenBIOS blob QEMU ships — no firmware build.
#
# CONSOLE DOCTRINE (inherited, and it bites harder here than on x86):
#  * pty ONLY. `-serial unix:` yields ZERO bytes from OpenBIOS on these
#    machines, so tools/drive-pty-repl.py is not a preference, it is the only
#    thing that works. (The sister lab drives a socket; that code cannot be
#    reused, which is one of the reasons this is its own lab.)
#  * the prompt is `0 >` — the STACK DEPTH, not `ok`. That makes every
#    `--expect "0 >"` a stack-balance assertion for free: a word that leaves
#    junk prompts `1 >` and the driver hangs instead of quietly continuing.
#    This is not hypothetical; it caught a leaked phandle during development.
#  * --echo-gate throughout, and it earns its keep in `console` below.
set -u
MODE="${1:-all}"
TRACK_ARG="${2:-sparc32}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${HABITAT_WORKDIR:-$HOME/ofhabitat-lab}"
DRIVE="$REPO/tools/drive-pty-repl.py"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
# House rule: no silent exits, ever.
# shellcheck disable=SC2154
trap 'rc=$?; [ $rc -eq 0 ] || [ $rc -eq 1 ] || [ $rc -eq 77 ] || echo "FAIL: smoke exited early (rc=$rc)"' EXIT

# shellcheck source=lib-habitat.sh
. "$HERE/lib-habitat.sh"
habitat_track "$TRACK_ARG" \
    || fail "usage: $0 [nvramrc|ladder|media|patch|autotrace|persist|console|all] [sparc32|ppc]"

command -v "$QEMU" >/dev/null || skip "$QEMU not installed (apt install qemu-system-sparc qemu-system-ppc)"
command -v python3 >/dev/null || skip "python3 not installed"
MIN="$WORKDIR/ofdiag.min.fth"

# strip ANSI + CRs so greps and awks see the text a human sees
clean() { sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\r//g' "$1"; }

# boot_and_drive <logname> <prom-env-and-media args as an array name> <drive-args...>
LOG=""
boot_and_drive() {
    local name="$1"; shift
    local -a extra=()
    while [ "${1:-}" != "--" ]; do extra+=("$1"); shift; done
    shift
    LOG="$WORKDIR/smoke-$name-$TRACK.log"
    rm -f "$LOG"
    python3 "$DRIVE" "$LOG" --timeout 240 --echo-gate "$@" \
        -- "$QEMU" "${QARGS[@]}" "${extra[@]}"
    local rc=$?
    [ -s "$LOG" ] || fail "no console output at all from $QEMU — see $LOG"
    return $rc
}

# Deliver the vocabulary through the NVRAM door. This is the ONLY door that
# works on both tracks, so every mode that needs ofdiag resident uses it.
nvram_args() {
    [ -f "$MIN" ] || { echo "SKIP"; return; }
    printf '%s\n' -prom-env "use-nvramrc?=true" -prom-env "nvramrc=$(cat "$MIN")"
}

# ── the vocabulary arrives, and arrives EARLY ────────────────────────────────
smoke_nvramrc() {
    [ -f "$MIN" ] || skip "no $MIN — run ./stage-dsl.sh"
    mapfile -t PROM < <(nvram_args)
    boot_and_drive nvramrc "${PROM[@]}" -- \
        --expect "ofdiag loaded" --expect "0 >" \
        --send 'why-no-boot\r' --expect "0 >" \
        || fail "the driver did not complete — see $LOG"
    # The claim is not merely "it ran" but "it ran BEFORE the firmware probed
    # and banner'd" — i.e. in the pre-probe window main.fs gives nvramrc.
    clean "$LOG" | awk '/ofdiag loaded/{seen=1} /Welcome to OpenBIOS/{exit seen?0:1}' \
        || fail "REGRESSION: nvramrc ran AFTER the banner — it is no longer in the pre-probe window (see $LOG)"
    note "the vocabulary loaded from NVRAM before probe-all and before the banner"
    # And the words must still be there at the prompt. If `device-end` is ever
    # dropped from the staged one-liner, they compile into whatever package is
    # active and vanish silently — the banner still prints, so ONLY this check
    # catches it.
    clean "$LOG" | grep -q 'why-no-boot: undefined word' \
        && fail "REGRESSION: the vocabulary's words did not survive to the prompt — the staged nvramrc is missing its leading 'device-end' (see $LOG)"
    clean "$LOG" | grep -q 'OFDIAG: boot-device =' \
        || fail "why-no-boot did not report boot-device — see $LOG"
    note "its words survived into the interactive dictionary (device-end held)"
    # The habitat's own boot policy, spelled out. If QEMU or OpenBIOS ever
    # changes the default, every table in the README and DELIVERY.md that quotes
    # it is stale — so pin it here rather than trusting prose.
    clean "$LOG" | grep -qF "OFDIAG: boot-device = $BOOTDEV" \
        || fail "boot-device is no longer '$BOOTDEV' on this machine — the README/PORTING tables quoting it are now stale (see $LOG)"
    note "boot-device is the documented $([ "$TRACK" = ppc ] && echo Apple || echo Sun) default: $BOOTDEV"
    pass "nvramrc ($TRACK): the diagnostic vocabulary is resident in NVRAM and self-installs at power-on"
}

# ── four DISTINCT diagnoses on a real machine ────────────────────────────────
smoke_ladder() {
    [ -f "$MIN" ] || skip "no $MIN — run ./stage-dsl.sh"
    mapfile -t PROM < <(nvram_args)
    # T_OPENOK on sparc32 is the cdrom, which only opens with a medium in it.
    local -a media=(); [ "$HAS_FS" = yes ] && media=("${MEDIA_ARGS[@]}")
    boot_and_drive ladder "${PROM[@]}" "${media[@]}" -- \
        --expect "ofdiag loaded" --expect "0 >" \
        --send "\" $T_NOALIAS\" diag-open\r"   --expect "0 >" \
        --send "\" $T_NONODE\" diag-open\r"    --expect "0 >" \
        --send "\" $T_OPENOK\" diag-open\r"    --expect "0 >" \
        --send "\" $T_OPENFAIL\" diag-open\r"  --expect "0 >" \
        || fail "the driver did not complete — see $LOG"
    local n
    for n in 0 1 2 3; do
        clean "$LOG" | grep -q "OFDIAG-$n:" \
            || fail "REGRESSION: fault class OFDIAG-$n never reported — the ported ladder stopped discriminating (see $LOG)"
    done
    note "four distinct fault classes on $MACHINE"
    # The alias rung must actually EXPAND, not just pass the string through.
    clean "$LOG" | grep -q "OFDIAG path:   /" \
        || fail "REGRESSION: no target ever resolved to an absolute path — expand-alias is not being consulted (see $LOG)"
    note "devalias expansion is visible in the OFDIAG path line"
    pass "ladder ($TRACK): the ported diagnosis ladder reports four distinct fault classes"
}

# ── the media door: SPARC has one, Apple does not ────────────────────────────
smoke_media() {
    if [ "$HAS_FS" != yes ]; then
        skip "media ($TRACK): the firmware compiles NO filesystem — ppc_config.xml disables every CONFIG_FSYS_*, leaving HFS/HFS+ only, so there is nothing to stage a .fth file on (see DELIVERY.md)"
    fi
    [ -f "$WORKDIR/dsl.iso" ] || skip "no $WORKDIR/dsl.iso — run ./stage-dsl.sh"
    # NB: NO -prom-env here. If the vocabulary shows up, it can only have come
    # off the disc — that is the whole point of the mode.
    boot_and_drive media "${MEDIA_ARGS[@]}" -- \
        --expect "0 >" \
        --send "$LOADCMD\r" --expect "0 >" \
        --send 'load-size . cr\r' --expect "0 >" \
        --send 'load-base load-size evaluate\r' --expect "ofdiag loaded" \
        --send 'why-no-boot\r' --expect "0 >" \
        || fail "the driver did not complete — see $LOG"
    # `load` FAILS SILENTLY: $load's open-dev returns 0 and the word just exits,
    # printing `ok`. A run that never noticed would "pass" on an empty buffer,
    # so assert the size is non-zero rather than trusting the ok.
    # The console echoes the typed line and the word's output on the SAME line
    # ("0 > load-size . cr 134c"), so match there, not on the line after. And
    # remember the base is HEX — 134c is 4940 bytes, not 4,940-ish decimal.
    clean "$LOG" | grep -oE 'load-size \. cr +[0-9a-f]+' | grep -qE ' [1-9a-f][0-9a-f]*$' \
        || fail "REGRESSION: load-size is 0 after '$LOADCMD' — the file did not come off the disc (note the Sun idiom has NO comma; see $LOG)"
    note "the firmware read OFDIAG.FTH off ISO9660 into load-base"
    clean "$LOG" | grep -q 'OFDIAG: boot-device =' \
        || fail "the evaluated vocabulary did not run — see $LOG"
    note "load-base load-size evaluate installed the vocabulary from media alone"
    pass "media ($TRACK): the vocabulary loads off a disc the firmware mounts itself"
}

# ── does a setenv SURVIVE a reset? The two habitats disagree ─────────────────
# The x86 sibling learned this the hard way in another guise: "it stuck" across
# a printenv in the SAME session is not evidence of non-volatility. Both arms
# below therefore reset the machine and look again.
smoke_persist() {
    local script='device-end : q ." PERSISTED-ACROSS-RESET" cr ; q'
    if [ "$CAN_PERSIST" = yes ]; then
        boot_and_drive persist -- \
            --expect "0 >" \
            --send "setenv nvramrc $script\r" --expect "0 >" \
            --send 'setenv use-nvramrc? true\r' --expect "0 >" \
            --send '" update-nvram" " nvram" open-dev $call-method\r' --expect "0 >" \
            --send 'reset-all\r' --expect "PERSISTED-ACROSS-RESET" \
            --expect "0 >" \
            || fail "the driver did not complete — see $LOG"
        note "setenv + the /nvram node's update-nvram method + reset-all"
        pass "persist ($TRACK): a config variable written from the ok prompt survives a machine reset and runs at power-on"
    fi
    # The negative arm. This is deterministic, not a coin-flip: sun4m simply has
    # no update-nvram to call (drivers/obio.c builds a bare eeprom node), so the
    # write can only ever live in the in-memory /options property.
    boot_and_drive persist -- \
        --expect "0 >" \
        --send "setenv nvramrc $script\r" --expect "0 >" \
        --send 'setenv use-nvramrc? true\r' --expect "0 >" \
        --send 'reset-all\r' --expect "Welcome to OpenBIOS" \
        --expect "0 >" \
        --send 'printenv use-nvramrc?\r' --expect "0 >" \
        || fail "the driver did not complete — see $LOG"
    clean "$LOG" | awk '/reset-all/{f=1} f' | grep -q 'PERSISTED-ACROSS-RESET' \
        && fail "sun4m NVRAM now PERSISTS a setenv — upstream has probably bound the nvram package to /obio/eeprom. That is good news, but DELIVERY.md and lib-habitat.sh's CAN_PERSIST=no are now wrong (see $LOG)"
    note "the setenv did NOT survive the reset, as the missing binding predicts"
    clean "$LOG" | awk '/printenv/{f=1} f' | grep -q 'use-nvramrc?  *"false"' \
        || fail "expected use-nvramrc? back at its default \"false\" after the reset — see $LOG"
    note "use-nvramrc? is back to its default: the write never reached the chip"
    pass "persist ($TRACK): setenv is session-only here — no update-nvram method exists to flush it (the honest negative)"
}

# ── why nobody types a vocabulary in ─────────────────────────────────────────
# Guards DELIVERY.md's claim that there is no "just type it" door. Not a
# curiosity: it is the reason stage-dsl.sh exists at all.
smoke_console() {
    local long; long="$(python3 -c "print('\\\\ ' + 'abcdefghij'*25)")"   # an inert 252-char COMMENT
    boot_and_drive console -- \
        --expect "0 >" --send "$long\r" --expect "0 >"
    local rc=$?
    [ $rc -eq 125 ] \
        || fail "REGRESSION: a 252-character line went through (driver rc=$rc, expected 125) — the console limit DELIVERY.md documents is gone, and the media/NVRAM doors may no longer be necessary (see $LOG)"
    note "--echo-gate reported the stall (exit 125) instead of silently mangling the line"
    local echoed
    echoed=$(clean "$LOG" | tail -1 | sed 's/.*0 > \\ //' | tr -cd 'a-j' | wc -c)
    [ "$echoed" -ge 70 ] && [ "$echoed" -le 86 ] \
        || fail "the console stopped echoing after $echoed characters, not the ~78 measured for an 80-column line — see $LOG"
    note "the console echoed $echoed characters (80 including the '\\ ' prefix) and then stopped accepting input"
    pass "console ($TRACK): typed input dies at 80 columns, which is why the vocabulary arrives by NVRAM or disc instead"
}

# ── patch (7.5.3.3), which the firmware ships empty ──────────────────────────
# The interesting assertion is the NEGATIVE one. A word's body is a run of xts
# with inline data interleaved (branch targets, literals, counted strings), so a
# naive "scan every cell for old-xt" would corrupt any literal that happens to
# hold the same bit pattern. The test builds exactly that booby trap on purpose.
smoke_patch() {
    if [ "$HAS_FS" != yes ]; then
        # patch.fth is 1466 B minified; it reaches ppc through the NVRAM door in
        # the `autotrace` mode below, which is where ppc's coverage lives.
        skip "patch ($TRACK): needs the media door to load patch.fth interactively; ppc has no filesystem — its coverage is the autotrace mode (see DELIVERY.md)"
    fi
    [ -f "$WORKDIR/dsl.iso" ] || skip "no $WORKDIR/dsl.iso — run ./stage-dsl.sh"
    boot_and_drive patch "${MEDIA_ARGS[@]}" -- \
        --expect "0 >" \
        --send 'load cdrom:\PATCH.FTH\r' --expect "0 >" \
        --send 'load-base load-size evaluate\r' --expect "patch loaded" \
        --send ': zap ." ZAP" cr ;\r' --expect "0 >" \
        --send ': zip ." ZIP" cr ;\r' --expect "0 >" \
        --send ': t4 zap 12345 drop zap ;\r' --expect "0 >" \
        --send "' zap true 12345 true ' t4 (patch)\r" --expect "0 >" \
        --send 'patch-count u. cr\r' --expect "0 >" \
        --send 'see t4\r' --expect "0 >" \
        --send 'patch zip zap t4\r' --expect "0 >" \
        --send 'see t4\r' --expect "0 >" \
        --send 't4\r' --expect "0 >" \
        || fail "the driver did not complete — see $LOG"
    # 1. literal mode: the (patch) call replaced the literal 12345 with the
    #    VALUE of ' zap, arming the trap.
    clean "$LOG" | grep -q 'patch-count u\. cr *1' \
        || fail "REGRESSION: (patch) in literal mode did not replace the literal 12345 — see $LOG"
    clean "$LOG" | grep -q '( lit ) h# ' \
        || fail "the decompiler shows no literal in t4 — the trap was never armed, so the negative control below proves nothing (see $LOG)"
    note "literal mode: (patch) set t4's literal to the value of ' zap"
    # 2. word mode: EXACTLY the two real call sites, not the literal.
    clean "$LOG" | grep -q 'patch: 2 occurrence(s) replaced' \
        || fail "REGRESSION: patch did not replace exactly 2 call sites. 3 means it clobbered the literal holding ' zap's bit pattern — /body-item is no longer stepping over inline data (see $LOG)"
    note "word mode: exactly 2 call sites rewritten, the identical-looking literal untouched"
    # 3. and it is real execution, not just a prettier decompile.
    clean "$LOG" | awk '/patch: 2 occurrence/{f=1} f' | grep -q 'ZIP' \
        || fail "the patched word still does not run the replacement — see $LOG"
    clean "$LOG" | awk '/patch: 2 occurrence/{f=1} f' | grep -q 'ZAP' \
        && fail "REGRESSION: the patched word still executes the ORIGINAL word — see $LOG"
    note "the patched word executes the replacement and never the original"
    pass "patch ($TRACK): 7.5.3.3 implemented over the dictionary, and it steps over inline data instead of scanning memory"
}

# ── the payoff: the power-on autoboot traces itself ──────────────────────────
smoke_autotrace() {
    AT="$WORKDIR/autotrace.min.fth"
    [ -f "$AT" ] || skip "no $AT — run ./stage-dsl.sh"
    # Send NOTHING before the prompt: the autoboot is the entire point, and the
    # first step only waits.
    boot_and_drive autotrace -prom-env "use-nvramrc?=true" -prom-env "nvramrc=$(cat "$AT")" -- \
        --expect "0 >" \
        --send 'trace-sites u. cr\r' --expect "0 >" \
        || fail "the driver did not complete — see $LOG"
    clean "$LOG" | grep -q '#T tracing ON, 2 call site(s) rewritten' \
        || fail "the tracers were not armed from NVRAM — see $LOG"
    # Armed BEFORE the firmware probed anything, which is what makes the
    # autoboot traceable at all.
    clean "$LOG" | awk '/#T tracing ON/{seen=1} /Welcome to OpenBIOS/{exit seen?0:1}' \
        || fail "REGRESSION: the tracers were armed AFTER the banner — no longer in nvramrc's pre-probe window (see $LOG)"
    note "patch + tracers arrived from NVRAM and rewrote 2 call sites before probe-all"
    # The proof: #T lines between the banner and the FIRST prompt — i.e. during
    # the power-on autoboot, with nothing typed.
    clean "$LOG" | awk '/Welcome to OpenBIOS/{f=1} /^0 >/{exit} f' | grep -q '#T load-begin' \
        || fail "REGRESSION: the POWER-ON autoboot was not traced (no #T load-begin before the first prompt) — see $LOG"
    clean "$LOG" | awk '/Welcome to OpenBIOS/{f=1} /^0 >/{exit} f' | grep -q '#T open' \
        || fail "REGRESSION: the autoboot's device open was not traced (no #T open before the first prompt) — see $LOG"
    note "the power-on autoboot traced itself — nothing typed, no hook in the firmware"
    pass "autotrace ($TRACK): tracers built on our own patch, delivered by NVRAM, catch the autoboot on a firmware that ships no tracepoints"
}

case "$MODE" in
    patch)     smoke_patch ;;
    autotrace) smoke_autotrace ;;
    nvramrc) smoke_nvramrc ;;
    ladder)  smoke_ladder ;;
    media)   smoke_media ;;
    persist) smoke_persist ;;
    console) smoke_console ;;
    all)
        rc=0
        for m in nvramrc ladder media patch autotrace persist console; do
            printf '\n=== %s (%s) ===\n' "$m" "$TRACK"
            bash "$0" "$m" "$TRACK"; r=$?
            [ $r -eq 1 ] && rc=1
        done
        printf '\n'
        [ $rc -eq 0 ] && echo "PASS: every claim verified ($TRACK)" || echo "FAIL: at least one claim failed ($TRACK)"
        exit $rc ;;
    *) fail "usage: $0 [nvramrc|ladder|media|patch|autotrace|persist|console|all] [sparc32|ppc]" ;;
esac
