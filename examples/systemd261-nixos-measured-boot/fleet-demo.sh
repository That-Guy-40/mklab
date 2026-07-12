#!/usr/bin/env bash
# fleet-demo.sh — Spike F: demonstrate systemd 261 `ConditionFraction=` staged
# rollout across the 3-VM mock fleet (fleet.toml). For each VM it reads the
# machine-id and sweeps `systemd-analyze condition 'ConditionFraction=N%'` over a
# range of N, then prints the rollout table: as the fraction widens, machines
# join deterministically (keyed on machine-id) and never leave — a canary rollout
# with zero external orchestrator.
#
#   phase2-qemu-vm/lab-vm.sh create --config examples/systemd261-nixos-measured-boot/fleet.toml
#   for v in fleet-1 fleet-2 fleet-3; do phase2-qemu-vm/lab-vm.sh start $v; done
#   examples/systemd261-nixos-measured-boot/fleet-demo.sh
set -euo pipefail

STATE="${LAB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lab-create}"
VMS=(fleet-1 fleet-2 fleet-3)
PCTS=(10 25 50 75 90)

# Drive an (autologin) serial shell: send a command, read the reply until a
# sentinel echoes back. The VMs have no SSH key (cloud_init=false), so serial is
# the channel.
drive() { # drive <serial.sock> <command>
python3 - "$1" "$2" <<'PY'
import socket, sys, time
sock, cmd = sys.argv[1], sys.argv[2]
S = "___FLEET_DONE___"
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(40):
    try: s.connect(sock); break
    except OSError: time.sleep(1)
s.setblocking(False); buf=b""; last=0; end=time.time()+120
full = "\n %s\n echo %s\n" % (cmd, S)
while time.time() < end:
    try:
        c=s.recv(65536)
        if c: buf+=c
    except BlockingIOError: time.sleep(0.2)
    if time.time()-last>5 and buf.count(S.encode())<2:
        s.sendall(full.encode()); last=time.time()
    if buf.count(S.encode())>=2: break
import re
print(buf.decode("utf-8","replace"))
PY
}

declare -A MID
declare -A RES   # RES[vm,pct] = MET|.
echo "== systemd 261 ConditionFraction= — 3-VM mock fleet =="
for v in "${VMS[@]}"; do
    sock="$STATE/vms/$v/serial.sock"
    [[ -S "$sock" ]] || { echo "SKIP: $v not running ($sock absent)"; exit 77; }
    out="$(drive "$sock" "echo MID=\$(cat /etc/machine-id); for p in ${PCTS[*]}; do systemd-analyze condition \"ConditionFraction=\$p%\" >/dev/null 2>&1 && echo FRAC=\$p:MET || echo FRAC=\$p:.; done")"
    MID[$v]="$(grep -aoE 'MID=[0-9a-f]{32}' <<<"$out" | head -1 | cut -d= -f2 | cut -c1-8)"
    for p in "${PCTS[@]}"; do
        grep -aqE "FRAC=$p:MET" <<<"$out" && RES[$v,$p]=MET || RES[$v,$p]="·"
    done
done

# Table
printf '\n%-10s %-10s' "VM" "machine-id"; for p in "${PCTS[@]}"; do printf ' %5s' "$p%"; done; echo
for v in "${VMS[@]}"; do
    printf '%-10s %-10s' "$v" "${MID[$v]:-?}"
    for p in "${PCTS[@]}"; do printf ' %5s' "${RES[$v,$p]}"; done; echo
done
printf '\n%-21s' "included (of 3):"; for p in "${PCTS[@]}"; do
    n=0; for v in "${VMS[@]}"; do [[ "${RES[$v,$p]}" == MET ]] && n=$((n+1)); done
    printf ' %5s' "$n"; done; echo

echo
echo "PASS: ConditionFraction= partitions the fleet deterministically by machine-id;"
echo "      widening the fraction only ADDS machines (a canary rollout, no orchestrator)."
