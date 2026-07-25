#!/usr/bin/env bash
# bmc.sh — one protocol-agnostic out-of-band verb surface over swappable backends
# (vbmcd / ipmi_sim / redfish). The reusable core of the BMC toolkit (plan §3):
# consumers call `bmc.sh <node> <verb>` and don't care which protocol reaches the metal;
# a capability model makes every backend declare what it faithfully implements, so an
# unsupported verb is refused loudly — never a silent no-op or a faked success.
#
#   bmc.sh [--backend B] <node> <verb> [args]
#   bmc.sh list
#
# verbs: bmc-up | bmc-down | inspect [--json]
#        power {on|off|cycle|status} | bootdev {pxe|disk|cdrom}
#        sol | insert-media <iso> | eject-media
#        sensors | fru | sel | identify {on|off}
set -euo pipefail

BMC_TOOLKIT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export BMC_TOOLKIT_DIR
REGISTRY="${BMC_REGISTRY:-${BMC_TOOLKIT_DIR}/fleet-bmc.toml}"
REG_PY="${BMC_TOOLKIT_DIR}/lib/registry.py"

usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---- global flags ----
BACKEND_OVERRIDE=""
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --backend) BACKEND_OVERRIDE="$2"; shift 2;;
    -h|--help) usage 0;;
    *) echo "unknown flag: $1" >&2; usage 2;;
  esac
done

[[ $# -ge 1 ]] || usage 2

# ---- meta verb with no node: list ----
if [[ "$1" == "list" ]]; then
  printf '%-8s %-9s %s\n' NODE BACKEND ENDPOINT
  while read -r n; do
    [[ -n "$n" ]] || continue
    eval "$(python3 "$REG_PY" "$REGISTRY" get "$n")"
    ep="${NODE_REDFISH_URL:-${NODE_IPMI_HOST:-?}:${NODE_IPMI_PORT:-}}"
    printf '%-8s %-9s %s\n' "$n" "${NODE_BACKEND:-?}" "$ep"
  done < <(python3 "$REG_PY" "$REGISTRY" list)
  exit 0
fi

NODE="$1"; shift
[[ $# -ge 1 ]] || usage 2
VERB="$1"; shift

# ---- resolve node params + backend ----
export NODE_NAME="$NODE"
if python3 "$REG_PY" "$REGISTRY" get "$NODE" >/dev/null 2>&1; then
  eval "$(python3 "$REG_PY" "$REGISTRY" get "$NODE")"
  # re-export NODE_* so backends (child scope via source) see them
  while IFS='=' read -r k _; do [[ "$k" == NODE_* ]] && export "${k?}"; done \
    < <(python3 "$REG_PY" "$REGISTRY" get "$NODE")
elif [[ -z "$BACKEND_OVERRIDE" ]]; then
  echo "bmc: node '$NODE' not in $REGISTRY (and no --backend given)" >&2; exit 1
fi
BACKEND="${BACKEND_OVERRIDE:-${NODE_BACKEND:-}}"
[[ -n "$BACKEND" ]] || { echo "bmc: no backend for '$NODE'" >&2; exit 1; }
export NODE_BACKEND="$BACKEND"

# ---- load common + backend ----
# shellcheck source=backends/common.sh
source "${BMC_TOOLKIT_DIR}/backends/common.sh"
BK_FILE="${BMC_TOOLKIT_DIR}/backends/${BACKEND}.sh"
[[ -f "$BK_FILE" ]] || { echo "bmc: unknown backend '$BACKEND' ($BK_FILE)" >&2; exit 1; }
declare -A CAP=() CAP_HINT=()
# shellcheck source=/dev/null
source "$BK_FILE"

# ---- meta verbs ----
case "$VERB" in
  inspect)
    if [[ "${1:-}" == "--json" ]]; then
      { printf '{"node":"%s","backend":"%s","capabilities":{' "$NODE" "$BACKEND"
        first=1; for v in "${!CAP[@]}"; do [[ $first == 1 ]] || printf ','; printf '"%s":"%s"' "$v" "${CAP[$v]}"; first=0; done
        printf '}}\n'; } | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin),indent=2,sort_keys=True))'
    else
      printf '%s  backend=%s\n' "$NODE" "$BACKEND"
      for v in power bootdev sol insert-media eject-media sensors fru sel identify; do
        [[ -n "${CAP[$v]:-}" ]] && printf '  %-14s : %s\n' "$v" "${CAP[$v]}"
      done
    fi
    exit 0 ;;
  bmc-up)   declare -F bk_up   >/dev/null && bk_up   || bk_note "backend '$BACKEND' has no bmc-up"; exit 0 ;;
  bmc-down) declare -F bk_down >/dev/null && bk_down || bk_note "backend '$BACKEND' has no bmc-down"; exit 0 ;;
esac

# ---- capability-gated verbs ----
level="${CAP[$VERB]:-no}"
hint="${CAP_HINT[$VERB]:-}"
case "$level" in
  no)         bk_die "backend '$BACKEND' does not implement '$VERB'${hint:+ ($hint)}" ;;
  substitute) bk_note "'$VERB' on '$BACKEND' is a SUBSTITUTE, not native${hint:+: $hint}" ;;
  partial)    bk_note "'$VERB' on '$BACKEND' is PARTIAL/emulated${hint:+: $hint}" ;;
esac
fn="bk_${VERB//-/_}"
declare -F "$fn" >/dev/null || bk_die "backend '$BACKEND' declares '$VERB'=$level but implements no $fn()"
"$fn" "$@"
