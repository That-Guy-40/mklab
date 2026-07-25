#!/usr/bin/env bash
# mock-bmc.sh — a stand-in for bmc-toolkit's bmc.sh, so the MAAS state machine is
# fully headless-testable (no libvirt, no vbmcd, no root). It records every call
# and returns canned output shaped like the real vbmcd backend.
#
# Contract mirrors the real tool: `mock-bmc.sh <node> <verb> [args]` (node first).
# Knobs (env):
#   MOCK_BMC_LOG   — append "<node> <verb> <args>" here (one line per call)
#   MOCK_BMC_FAIL  — a verb name to fail on (exit 1), e.g. "power" to simulate a
#                    BMC that never answers (drives the node -> error path)
set -uo pipefail

node="${1:-}"; verb="${2:-}"; shift 2 2>/dev/null || true

[[ -n "${MOCK_BMC_LOG:-}" ]] && printf '%s %s %s\n' "$node" "$verb" "$*" >> "$MOCK_BMC_LOG"

if [[ -n "${MOCK_BMC_FAIL:-}" && "$verb" == "${MOCK_BMC_FAIL}" ]]; then
    printf 'mock-bmc: simulated failure for %s %s\n' "$node" "$verb" >&2
    exit 1
fi

case "$verb" in
    power)
        case "${1:-}" in
            status) printf 'Chassis Power is off\n' ;;
            on)     printf 'Chassis Power Control: Up/On\n' ;;
            off)    printf 'Chassis Power Control: Down/Off\n' ;;
            cycle)  printf 'Chassis Power Control: Cycle\n' ;;
            *)      printf 'mock-bmc: power: on|off|cycle|status\n' >&2; exit 1 ;;
        esac ;;
    bootdev) printf 'Set Boot Device to %s\n' "${1:-pxe}" ;;
    sol)     printf 'SUBSTITUTE: use: virsh console %s\n' "$node" >&2 ;;
    *)       printf 'mock-bmc: %s -> ok\n' "$verb" ;;
esac
exit 0
