#!/usr/bin/env bash
# mock-bmc.sh — a stand-in for bmc-toolkit's bmc.sh, so the MAAS state machine is
# fully headless-testable (no libvirt, no vbmcd, no root). It records every call
# and returns canned output shaped like the real vbmcd backend.
#
# Contract mirrors the real tool: `mock-bmc.sh <node> <verb> [args]` (node first).
#
# POWER IS STATEFUL. `power status` used to answer a hardcoded "off", which was fine
# while nothing polled it — but a driver that waits for a machine to power itself off
# would then "succeed" instantly, and the wait it is supposed to perform would go
# untested. So the mock now remembers what it was told, and `status` reports that.
#
# Knobs (env):
#   MOCK_BMC_LOG        — append "<node> <verb> <args>" here (one line per call)
#   MOCK_BMC_FAIL       — a verb name to fail on (exit 1), e.g. "power" to simulate a
#                         BMC that never answers (drives the node -> error path)
#   MOCK_BMC_POWER_DIR  — where per-node power state lives (default: beside the log)
#   MOCK_BMC_OFF_AFTER  — N: while powered on, the (N+1)th `power status` reports off.
#                         This is the installer finishing and powering ITSELF down —
#                         the completion signal the install driver waits for. Unset =
#                         the node stays on forever (the driver must time out).
#   MOCK_BMC_ACTUATES   — <other-node>: this BMC endpoint is BOUND TO A DIFFERENT
#                         MACHINE (the vbmc port-collision the second live run hit).
#                         Every power verb — `status` included — succeeds and answers
#                         TRUTHFULLY about that machine. That is what made the live
#                         incident invisible: four IPMI commands succeeded and not
#                         one answer was about the machine in the record.
#   MOCK_BMC_CONSOLE_DIR — when a machine ACTUALLY powers on, append a boot line to
#                         <dir>/<machine>.log. The console is bolted to the machine,
#                         not to the BMC, so it is the one witness a mis-bound BMC
#                         cannot fake — the ground truth console-reading health
#                         gates (like the real drivers') rest on.
set -uo pipefail

node="${1:-}"; verb="${2:-}"; shift 2 2>/dev/null || true

[[ -n "${MOCK_BMC_LOG:-}" ]] && printf '%s %s %s\n' "$node" "$verb" "$*" >> "$MOCK_BMC_LOG"

if [[ -n "${MOCK_BMC_FAIL:-}" && "$verb" == "${MOCK_BMC_FAIL}" ]]; then
    printf 'mock-bmc: simulated failure for %s %s\n' "$node" "$verb" >&2
    exit 1
fi

# The machine this BMC endpoint really operates. Normally the node it was addressed
# for; with MOCK_BMC_ACTUATES it is somebody else's machine, and everything below —
# state files, status answers, console output — belongs to THAT machine.
actuated="${MOCK_BMC_ACTUATES:-$node}"

# ---- chassis power state (per machine, on disk so it survives across invocations) ----
_pdir="${MOCK_BMC_POWER_DIR:-${MOCK_BMC_LOG:+${MOCK_BMC_LOG}.power.d}}"
_pfile=""; _cfile=""
if [[ -n "$_pdir" ]]; then
    mkdir -p "$_pdir" 2>/dev/null && { _pfile="$_pdir/$actuated.power"; _cfile="$_pdir/$actuated.polls"; }
fi
_pget() { [[ -n "$_pfile" && -f "$_pfile" ]] && cat "$_pfile" || printf 'off'; }
_pset() { [[ -n "$_pfile" ]] && printf '%s' "$1" > "$_pfile"; : > "${_cfile:-/dev/null}"; }
# the machine that really turned on speaks on ITS console (see MOCK_BMC_CONSOLE_DIR)
#
# MOCK_BMC_BOOT_SAYS — text this machine emits on its OWN console each time it really
# powers on, appended to $MAAS_STATE/<node>/console.log. It exists because a console is
# produced BY a boot: a test that pre-writes the success banner before deploying proves
# only that the driver can grep a file it was handed, and would keep passing after the
# driver started (correctly) ignoring output that predates the deploy. Real machines
# speak when you turn them on; so does this one.
_boot() {
    if [[ -n "${MOCK_BMC_BOOT_SAYS:-}" && -n "${MAAS_STATE:-}" ]]; then
        mkdir -p "$MAAS_STATE/$actuated" 2>/dev/null
        printf '%b\n' "$MOCK_BMC_BOOT_SAYS" >> "$MAAS_STATE/$actuated/console.log"
    fi
    [[ -n "${MOCK_BMC_CONSOLE_DIR:-}" ]] || return 0
    mkdir -p "$MOCK_BMC_CONSOLE_DIR" 2>/dev/null
    printf '[boot] %s: powered on, console alive\n' "$actuated" >> "$MOCK_BMC_CONSOLE_DIR/$actuated.log"
}

case "$verb" in
    power)
        case "${1:-}" in
            status)
                st="$(_pget)"
                # the self-poweroff at the end of an install, on a delay the test picks
                if [[ "$st" == on && -n "${MOCK_BMC_OFF_AFTER:-}" && -n "$_cfile" ]]; then
                    printf 'x' >> "$_cfile"
                    if [[ $(wc -c < "$_cfile") -gt ${MOCK_BMC_OFF_AFTER} ]]; then
                        if [[ "${MOCK_BMC_BLIP:-0}" == 1 && -n "$_pfile" ]]; then
                            # a power BLIP, not a completion: report off exactly ONCE;
                            # the machine is back on by the next poll (an out-of-band
                            # power cycle racing the driver's poweroff-wait — the
                            # observed incident the install driver's confirm poll
                            # exists to refuse).
                            if [[ ! -f "$_pfile.blipped" ]]; then
                                : > "$_pfile.blipped"; st=off
                            fi
                        else
                            _pset off; st=off
                        fi
                    fi
                fi
                printf 'Chassis Power is %s\n' "$st" ;;
            on)     _pset on;  _boot; printf 'Chassis Power Control: Up/On\n' ;;
            off)    _pset off; printf 'Chassis Power Control: Down/Off\n' ;;
            cycle)
                # MOCK_BMC_NO_CYCLE=1 — a BMC that does NOT implement chassis
                # power cycle. This is not hypothetical: vbmcd, the backend this
                # lab's own fleet runs on, answers exactly this way, while the
                # mock's happy `cycle` let a driver depend on a capability the
                # real seam lacks (found before the image driver's live run).
                if [[ "${MOCK_BMC_NO_CYCLE:-0}" == 1 ]]; then
                    printf 'Set Chassis Power Control to Cycle failed: Invalid data field in request\n' >&2
                    exit 1
                fi
                _pset on;  _boot; printf 'Chassis Power Control: Cycle\n' ;;
            *)      printf 'mock-bmc: power: on|off|cycle|status\n' >&2; exit 1 ;;
        esac ;;
    bootdev) printf 'Set Boot Device to %s\n' "${1:-pxe}" ;;
    sol)     printf 'SUBSTITUTE: use: virsh console %s\n' "$node" >&2 ;;
    *)       printf 'mock-bmc: %s -> ok\n' "$verb" ;;
esac
exit 0
