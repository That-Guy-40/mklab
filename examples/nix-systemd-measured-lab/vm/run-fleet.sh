#!/usr/bin/env bash
# run-fleet.sh — boot the SAME DDI as N VMs with distinct machine-ids and tags,
# to demonstrate rollout gating (Pillar 3: ConditionFraction= / ConditionMachineTag=).
#
# Every VM boots a copy-on-write overlay of ONE golden disk — so the ONLY thing
# that differs between them is local identity (machine-id + /etc/machine-info
# tag), injected via systemd credentials over SMBIOS.  Watch the canary unit
# fire on the tagged/selected minority and skip on the rest: a staged rollout
# with no orchestrator, off one image.
#
# [YOU-RUN-THIS] — needs qemu-system-x86_64 + qemu-img + OVMF + KVM.  Author-run.
#
# Usage:
#   ./run-fleet.sh --disk /path/to/nix-measured-install.qcow2 [--count 10] [--canary 2]
#
# --canary K tags the first K machines with MACHINE_TAGS=canary (deterministic
# proof of ConditionMachineTag=).  ConditionFraction=10% ALSO bucket-selects ~1
# in 10 by hash(machine-id) — the journal on every machine shows which gate, if
# any, let it through.

set -euo pipefail

disk=""; count=10; canary=1; accel="kvm"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk)   shift; disk="${1:?}"; shift ;;
    --count)  shift; count="${1:?}"; shift ;;
    --canary) shift; canary="${1:?}"; shift ;;
    --no-kvm) accel="tcg"; shift ;;
    --help|-h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done
[[ -n "$disk" && -f "$disk" ]] || { echo "error: --disk <existing qcow2> required" >&2; exit 1; }
command -v qemu-img >/dev/null || { echo "error: qemu-img not installed" >&2; exit 1; }

# OVMF (reuse run-measured-vm.sh's search would duplicate; keep it inline/minimal)
ovmf_code=""; for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
  [[ -f "$c" ]] && { ovmf_code="$c"; break; }; done
ovmf_vars=""; for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
  [[ -f "$v" ]] && { ovmf_vars="$v"; break; }; done
[[ -n "$ovmf_code" && -n "$ovmf_vars" ]] || { echo "error: OVMF not found" >&2; exit 1; }

workdir="$(mktemp -d "${TMPDIR:-/tmp}/nix-fleet.XXXXXX")"
pids=()
cleanup() {
  # Kill by RECORDED PID only (CLAUDE.md: never pattern-kill a shared path).
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

echo "[run-fleet] launching $count VMs ($canary tagged canary) from $disk" >&2
for i in $(seq 1 "$count"); do
  # A stable, distinct machine-id per VM (32 hex chars).
  mid="$(printf '%032x' "$((0xC0DE0000 + i))")"
  tag=""; [[ "$i" -le "$canary" ]] && tag="canary"

  overlay="$workdir/vm-$i.qcow2"
  qemu-img create -q -f qcow2 -F qcow2 -b "$disk" "$overlay" >/dev/null
  vars="$workdir/vars-$i.fd"; cp "$ovmf_vars" "$vars"
  log="$workdir/vm-$i.log"

  # systemd credentials over SMBIOS type 11:
  #   firstboot.machine-id  -> the per-VM identity ConditionFraction= hashes
  #   set MACHINE_TAGS       -> what ConditionMachineTag= reads (canary subset)
  creds=(-smbios "type=11,value=io.systemd.credential:firstboot.machine-id=$mid")
  [[ -n "$tag" ]] && creds+=(-smbios "type=11,value=io.systemd.credential:systemd.machine-info=MACHINE_TAGS=$tag")

  qemu-system-x86_64 \
    -machine q35,accel="$accel" -m 1024 -nographic \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$ovmf_code" \
    -drive if=pflash,format=raw,unit=1,file="$vars" \
    -drive if=virtio,format=qcow2,file="$overlay" \
    "${creds[@]}" \
    -serial "file:$log" >/dev/null 2>&1 &
  pids+=("$!")
done

echo "[run-fleet] booting; waiting ~90s for canary units to settle..." >&2
sleep 90

echo
echo "=== Rollout gating result (marker: CANARY-ACTIVE) ==================="
active=0
for i in $(seq 1 "$count"); do
  if grep -q "CANARY-ACTIVE" "$workdir/vm-$i.log" 2>/dev/null; then
    tag=""; [[ "$i" -le "$canary" ]] && tag=" (tagged)"
    echo "  vm-$i: CANARY-ACTIVE$tag"
    active=$((active + 1))
  else
    echo "  vm-$i: skipped (gate not satisfied)"
  fi
done
echo "===================================================================="
echo "canary active on $active/$count machines — off ONE golden image."
