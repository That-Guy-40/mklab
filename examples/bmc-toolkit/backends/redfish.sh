#!/usr/bin/env bash
# Backend: Redfish via sushy-tools (sushy-emulator). Modern OOB — power, boot-override,
# and the capability IPMI lacks: VIRTUAL MEDIA (InsertMedia -> boot an ISO, no PXE).
# Proven headless & rootless over qemu:///session (POC-B).

declare -A CAP=(
  [power]=yes [bootdev]=yes
  [sol]=partial
  [insert-media]=yes [eject-media]=yes
  [sensors]=partial [fru]=no [sel]=no [identify]=partial
)
declare -A CAP_HINT=(
  [sol]="sushy doesn't emulate Redfish SerialConsole; 'sol' tails the node's libvirt serial (honest stand-in)"
  [fru]="Redfish models inventory as Chassis/Processors, not IPMI FRU"
  [sel]="Redfish models events as LogServices; not wired in v1"
)

VENV="${BMC_TOOLKIT_DIR}/.venv"
SUSHY="${VENV}/bin/sushy-emulator"
PYBIN="${VENV}/bin/python"

_rf_venv() {
  if [[ ! -x "$SUSHY" ]]; then
    bk_note "bootstrapping sushy-tools venv (first run) …"
    python3 -m venv --system-site-packages "$VENV" >/dev/null
    "$VENV/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1 || true
    "$VENV/bin/pip" install --quiet 'sushy-tools==2.2.0' >/dev/null \
      || bk_die "pip install sushy-tools failed"
  fi
  [[ -x "$SUSHY" ]] || bk_die "sushy-emulator missing after venv bootstrap"
}

_rf() { local m="$1" p="$2"; shift 2; curl -sf -X "$m" "${NODE_REDFISH_URL:?}$p" "$@"; }
_rf_sys() {   # cache the system @odata.id  ('@odata.id' is one key with a dot, so use explicit py)
  [[ -n "${_RF_SYS:-}" ]] && { printf '%s' "$_RF_SYS"; return; }
  _RF_SYS="$(_rf GET /redfish/v1/Systems | "$PYBIN" -c 'import sys,json;print(json.load(sys.stdin)["Members"][0]["@odata.id"])')"
  printf '%s' "$_RF_SYS"
}

_rf_ensure_pool() {   # sushy _upload_image needs a libvirt storage pool (session has none)
  local dir; dir="$(bk_state_dir)/pool"; mkdir -p "$dir"
  virsh -c "${NODE_URI:?}" pool-info default >/dev/null 2>&1 || {
    virsh -c "$NODE_URI" pool-define-as default dir --target "$dir" >/dev/null
    virsh -c "$NODE_URI" pool-build default >/dev/null 2>&1 || true
  }
  virsh -c "$NODE_URI" pool-start default >/dev/null 2>&1 || true
}

bk_up() {
  bk_need python3 curl virsh
  _rf_venv
  _rf_ensure_pool
  local host="${NODE_REDFISH_URL#http://}"; host="${host%%:*}"
  local port="${NODE_REDFISH_URL##*:}"
  local sd; sd="$(bk_state_dir)"
  SUSHY_EMULATOR_STORAGE_POOL=default \
    "$SUSHY" --libvirt-uri "${NODE_URI:?}" -i "$host" -p "$port" >"$sd/sushy.log" 2>&1 &
  bk_savepid sushy "$!"
  local i; for i in $(seq 1 40); do curl -sf -o /dev/null "${NODE_REDFISH_URL}/redfish/v1/" && break; sleep 0.3; done
  curl -sf -o /dev/null "${NODE_REDFISH_URL}/redfish/v1/" \
    || { echo "sushy-emulator not responding:" >&2; cat "$sd/sushy.log" >&2; return 1; }
  bk_note "sushy-emulator up: ${NODE_REDFISH_URL} (libvirt ${NODE_URI})"
}
bk_down() { bk_killpid sushy; bk_killpid vmedia-http; }

bk_power() {
  local sys; sys="$(_rf_sys)"
  case "${1:-status}" in
    status) _rf GET "$sys" | "$PYBIN" -c 'import sys,json;print(json.load(sys.stdin)["PowerState"])' ;;
    on)     _rf POST "$sys/Actions/ComputerSystem.Reset" -H 'Content-Type: application/json' -d '{"ResetType":"On"}' -o /dev/null && echo "On" ;;
    off)    _rf POST "$sys/Actions/ComputerSystem.Reset" -H 'Content-Type: application/json' -d '{"ResetType":"ForceOff"}' -o /dev/null && echo "Off" ;;
    cycle)  _rf POST "$sys/Actions/ComputerSystem.Reset" -H 'Content-Type: application/json' -d '{"ResetType":"ForceRestart"}' -o /dev/null && echo "Cycled" ;;
    *) bk_die "power: on|off|cycle|status" ;;
  esac
}

bk_bootdev() {
  local sys tgt; sys="$(_rf_sys)"
  case "${1:?bootdev: pxe|disk|cdrom}" in
    pxe) tgt=Pxe;; disk) tgt=Hd;; cdrom|cd) tgt=Cd;;
    *) bk_die "bootdev: pxe|disk|cdrom";;
  esac
  _rf PATCH "$sys" -H 'Content-Type: application/json' \
    -d "{\"Boot\":{\"BootSourceOverrideEnabled\":\"Once\",\"BootSourceOverrideTarget\":\"$tgt\"}}" -o /dev/null \
    && echo "boot override -> $tgt (once)"
}

bk_insert_media() {
  local iso="${1:?insert-media <iso-path-or-url>}"
  local url="$iso"
  if [[ "$iso" != http://* && "$iso" != https://* ]]; then
    [[ -f "$iso" ]] || bk_die "no such ISO: $iso"
    # sushy fetches Image by HTTP (requests.get) — serve the ISO's dir over localhost.
    local dir base port; dir="$(cd "$(dirname "$iso")" && pwd)"; base="$(basename "$iso")"; port="${BMC_VMEDIA_HTTP_PORT:-8899}"
    ( cd "$dir" && exec "$PYBIN" -m http.server "$port" --bind 127.0.0.1 ) >"$(bk_state_dir)/vmedia-http.log" 2>&1 &
    bk_savepid vmedia-http "$!"; sleep 1
    url="http://127.0.0.1:${port}/${base}"
  fi
  local sys; sys="$(_rf_sys)"
  _rf POST "$sys/VirtualMedia/Cd/Actions/VirtualMedia.InsertMedia" \
    -H 'Content-Type: application/json' -d "{\"Image\":\"$url\",\"Inserted\":true}" -o /dev/null \
    && echo "inserted: $url"
}

bk_eject_media() {
  local sys; sys="$(_rf_sys)"
  _rf POST "$sys/VirtualMedia/Cd/Actions/VirtualMedia.EjectMedia" \
    -H 'Content-Type: application/json' -d '{}' -o /dev/null && echo "ejected"
  bk_killpid vmedia-http
}

bk_sol() { # honest stand-in: tail the node's captured libvirt serial
  local f="$(bk_state_dir)/node-serial.log"
  [[ -f "$f" ]] || bk_die "no captured serial at $f (start the node with serial->file)"
  bk_note "Redfish SerialConsole not emulated by sushy; showing the node's libvirt serial"
  tail -n "${BMC_SOL_LINES:-40}" "$f"
}
bk_sensors() { local sys; sys="$(_rf_sys)"; _rf GET "$sys" | "$PYBIN" -c 'import sys,json;d=json.load(sys.stdin);print("PowerState:",d.get("PowerState"),"| Health:",(d.get("Status") or {}).get("Health"))'; }
