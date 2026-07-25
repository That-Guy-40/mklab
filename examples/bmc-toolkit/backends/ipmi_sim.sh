#!/usr/bin/env bash
# Backend: OpenIPMI ipmi_sim — REAL IPMI Serial-over-LAN over RMCP+/lanplus.
# Proven headless & rootless (POC-A). Power/bootdev are NOT offered here: ipmi_sim's
# chassis-control returns 0xCC in 1.0.13, so this backend does what it uniquely can —
# real SOL — and power/bootdev live on a coexisting vbmcd (the "coexist" shape, plan §5).

declare -A CAP=(
  [power]=no  [bootdev]=no
  [sol]=yes
  [sensors]=partial [fru]=partial [sel]=partial [identify]=no
  [insert-media]=no [eject-media]=no
)
declare -A CAP_HINT=(
  [power]="ipmi_sim chassis-control is 0xCC in this build; drive power via a coexisting vbmcd backend (see README: coexist)"
  [bootdev]="same as power — use the coexisting vbmcd backend for boot-device"
  [insert-media]="virtual media is a Redfish capability — use a redfish-backed node"
)

_ipmisim_soldev() {
  # SOL device: the node's serial. tcp:host:port (QEMU <serial type='tcp'>) if serial_tcp
  # is set, else an explicit BMC_SOL_DEVICE (e.g. a PTY path).
  if [[ -n "${NODE_SERIAL_TCP:-}" ]]; then
    printf 'tcp:%s:%s' "${NODE_IPMI_HOST:-127.0.0.1}" "${NODE_SERIAL_TCP}"
  elif [[ -n "${BMC_SOL_DEVICE:-}" ]]; then
    printf '%s' "$BMC_SOL_DEVICE"
  else
    bk_die "no SOL device: set serial_tcp in the registry or BMC_SOL_DEVICE"
  fi
}

bk_up() {
  bk_need ipmi_sim ipmitool
  local sd; sd="$(bk_state_dir)"
  local dev; dev="$(_ipmisim_soldev)"
  sed -e "s#@@LAN_HOST@@#${NODE_IPMI_HOST:-127.0.0.1}#" \
      -e "s#@@LAN_PORT@@#${NODE_IPMI_PORT:?}#" \
      -e "s#@@SOL_DEVICE@@#${dev}#" \
      -e "s#@@USER@@#${NODE_IPMI_USER:-ipmiusr}#" \
      -e "s#@@PASS@@#${NODE_IPMI_PASS:-test}#" \
      "${BMC_TOOLKIT_DIR}/nodes/lan.conf.template" > "$sd/lan.conf"
  mkdir -p "$sd/state"
  # -n (console off; -d core-dumps in 1.0.13), -s writable state dir (POC-A gotchas).
  ipmi_sim -c "$sd/lan.conf" -f "${BMC_TOOLKIT_DIR}/nodes/ipmisim.emu" -n -s "$sd/state" \
    >"$sd/ipmi_sim.log" 2>&1 &
  bk_savepid ipmi_sim "$!"
  sleep 1
  kill -0 "$(cat "$sd/ipmi_sim.pid")" 2>/dev/null \
    || { echo "ipmi_sim failed to start:" >&2; cat "$sd/ipmi_sim.log" >&2; return 1; }
  bk_note "ipmi_sim up: RMCP+ ${NODE_IPMI_HOST:-127.0.0.1}:${NODE_IPMI_PORT}  SOL<-${dev}"
}

bk_down() { bk_killpid ipmi_sim; }

_ipmi() { ipmitool -I lanplus -H "${NODE_IPMI_HOST:-127.0.0.1}" -p "${NODE_IPMI_PORT:?}" \
                   -U "${NODE_IPMI_USER:-ipmiusr}" -P "${NODE_IPMI_PASS:-test}" -C 3 "$@"; }

bk_sol() {
  # Real SOL. Capture mode (BMC_SOL_CAPTURE=<seconds>) holds stdin OPEN with a slow pipe
  # then exits — because `sol activate </dev/null` tears the session down on EOF (POC-A).
  # Otherwise run interactively against the caller's terminal (~. to exit).
  if [[ -n "${BMC_SOL_CAPTURE:-}" ]]; then
    { sleep "${BMC_SOL_CAPTURE}"; } | _ipmi sol activate
  else
    _ipmi sol activate
  fi
}

# Passthroughs — return whatever ipmi_sim actually reports (v1 emu is minimal => partial).
bk_sensors() { _ipmi sdr list 2>&1 || true; }
bk_fru()     { _ipmi fru print 2>&1 || true; }
bk_sel()     { _ipmi sel list 2>&1 || true; }
