#!/usr/bin/env bash
# run-measured-vm.sh — boot the on-disk DDI WITH a software TPM, so the boot is
# actually measured (Pillar 1).
#
# WHY A SEPARATE HARNESS?  phase2-qemu-vm/lab-vm.sh has no vTPM support (no
# -tpmdev / swtpm), and measured boot needs PCRs.  Rather than thread a swtpm
# daemon lifecycle through lab-vm.sh's create/start/stop/destroy, this lab ships
# a self-contained raw-QEMU launcher — the same pattern as the FreeBSD and
# libvirt labs that also run outside lab-vm.sh.  (A `tpm` field for lab-vm.sh is
# sketched as future work in ../PLAN.md.)
#
# It reuses the SAME OVMF pflash wiring lab-vm.sh uses (code RO + a per-VM
# writable VARS copy), and adds:
#   swtpm socket  +  -tpmdev emulator  +  -device tpm-crb
#
# [YOU-RUN-THIS] — needs qemu-system-x86_64, swtpm, and OVMF.  None are in the
# lab CI container; author-run on a KVM host.
#
# Usage:
#   ./run-measured-vm.sh --disk /path/to/nix-measured-install.qcow2 [--no-kvm]
#
# Then, at the serial console (login lab/lab):
#   journalctl -u measured-os-check   # -> "MEASURED-OS: boot measured, PCR11=..."
#   systemd-analyze pcrs              # PCR 11 non-zero
#   journalctl -u verity-exec-restrict # -> "EXEC-RESTRICT: off-store exec denied"

set -euo pipefail

disk=""
accel="kvm"
mem="2048"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk)   shift; disk="${1:?--disk requires a path}"; shift ;;
    --no-kvm) accel="tcg"; shift ;;
    --mem)    shift; mem="${1:?--mem requires MiB}"; shift ;;
    --help|-h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

[[ -n "$disk" ]] || { echo "error: --disk is required" >&2; exit 1; }
[[ -f "$disk"  ]] || { echo "error: disk not found: $disk" >&2; exit 1; }
command -v swtpm >/dev/null || { echo "error: swtpm not installed" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "error: qemu-system-x86_64 not installed" >&2; exit 1; }

# ── Locate OVMF (same search lab-vm.sh does) ────────────────────────────────
ovmf_code=""; ovmf_vars_template=""
for c in \
  /usr/share/OVMF/OVMF_CODE_4M.fd \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/edk2/x64/OVMF_CODE.4m.fd \
  /usr/share/qemu/OVMF_CODE.fd; do
  [[ -f "$c" ]] && { ovmf_code="$c"; break; }
done
for v in \
  /usr/share/OVMF/OVMF_VARS_4M.fd \
  /usr/share/OVMF/OVMF_VARS.fd \
  /usr/share/edk2/x64/OVMF_VARS.4m.fd \
  /usr/share/qemu/OVMF_VARS.fd; do
  [[ -f "$v" ]] && { ovmf_vars_template="$v"; break; }
done
[[ -n "$ovmf_code" && -n "$ovmf_vars_template" ]] || {
  echo "error: OVMF firmware not found (install ovmf / edk2-ovmf)" >&2; exit 1; }

# ── Per-run working dir (writable VARS copy + swtpm state + sockets) ─────────
workdir="$(mktemp -d "${TMPDIR:-/tmp}/nix-measured-vm.XXXXXX")"
vars="$workdir/OVMF_VARS.fd"
cp "$ovmf_vars_template" "$vars"
tpmstate="$workdir/tpm"; mkdir -p "$tpmstate"
tpmsock="$workdir/swtpm.sock"

swtpm_pid=""
cleanup() {
  # Kill by RECORDED PID, never by pattern (a serial.sock/swtpm.sock pattern
  # would also match QEMU itself — see CLAUDE.md).
  [[ -n "$swtpm_pid" ]] && kill "$swtpm_pid" 2>/dev/null || true
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

# ── Spawn the software TPM (TPM 2.0) ────────────────────────────────────────
echo "[run-measured-vm] starting swtpm (state=$tpmstate)" >&2
swtpm socket \
  --tpmstate dir="$tpmstate" \
  --ctrl type=unixio,path="$tpmsock" \
  --tpm2 \
  --flags startup-clear &
swtpm_pid=$!
# Wait for the control socket to appear before launching QEMU.
for _ in $(seq 1 50); do [[ -S "$tpmsock" ]] && break; sleep 0.1; done
[[ -S "$tpmsock" ]] || { echo "error: swtpm socket never appeared" >&2; exit 1; }

# ── Launch QEMU: OVMF (two-file pflash) + vTPM + the on-disk DDI ─────────────
echo "[run-measured-vm] booting $disk with a measured TPM (accel=$accel)" >&2
exec qemu-system-x86_64 \
  -machine q35,accel="$accel" \
  -m "$mem" \
  -nographic \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$ovmf_code" \
  -drive if=pflash,format=raw,unit=1,file="$vars" \
  -drive if=virtio,format=qcow2,file="$disk" \
  -chardev socket,id=chrtpm,path="$tpmsock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-crb,tpmdev=tpm0 \
  -serial mon:stdio
