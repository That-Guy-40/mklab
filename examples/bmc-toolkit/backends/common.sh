#!/usr/bin/env bash
# Shared helpers + the capability-model vocabulary for bmc.sh backends.
#
# Each backend (sourced by bmc.sh) declares:
#   declare -A CAP=( [power]=yes [bootdev]=yes [sol]=... )   # verb -> level
#   bk_<verb>() { ... }                                       # implementation
# and may define bk_up / bk_down (lifecycle: start/stop the node's BMC daemon).
#
# Capability LEVELS (the honesty spine, plan §3/§6):
#   yes        - faithfully implemented by this protocol/backend
#   partial    - present but limited/emulated (flagged; not a full BMC surface)
#   substitute - NOT this protocol, an honest stand-in (e.g. vbmcd "sol" = libvirt console)
#   no         - not implemented; the verb is refused with a clear, non-zero error
#
# bmc.sh consults CAP before dispatch: 'no' -> refuse loudly (never a silent no-op);
# 'substitute' -> proceed but print the caveat.

bk_die()  { printf 'bmc: %s\n' "$*" >&2; exit 1; }
bk_note() { printf '  - %s\n' "$*" >&2; }
bk_have() { command -v "$1" >/dev/null 2>&1; }
bk_need() { local c; for c in "$@"; do bk_have "$c" || bk_die "missing required command: $c"; done; }

# A per-node runtime/state dir for pidfiles, rendered configs, captured serial.
bk_state_dir() {
  local d="${BMC_STATE_ROOT:-${BMC_TOOLKIT_DIR}/state}/${NODE_NAME:?}"
  mkdir -p "$d"; printf '%s' "$d"
}

# Record/kill a backend daemon strictly by PID (never pkill -f: ipmi_sim/sushy/qemu share
# cmdline substrings — the house footgun).
bk_savepid() { echo "$2" > "$(bk_state_dir)/$1.pid"; }
bk_killpid() {
  local pf="$(bk_state_dir)/$1.pid"
  [[ -f "$pf" ]] || return 0
  local pid; pid="$(cat "$pf")"
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  rm -f "$pf"
}
