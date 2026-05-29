#!/usr/bin/env bash
# Unit test: the `firmware = bios|uefi` selector.
#   - firmware_for(x86_64, …, bios) → empty  → QEMU's built-in SeaBIOS, so
#     build_qemu_argv emits NO `if=pflash` / `-bios` (lets a BIOS-MBR iPXE ROM
#     boot the two-disk PXE loop on a host that defaults to UEFI).
#   - firmware_for(x86_64, …, uefi) → an OVMF blob → a `-drive if=pflash`.
# No QEMU boot; sources lab-vm.sh and inspects firmware_for + QEMU_ARGV.

# shellcheck disable=SC2034  (globals consumed by sourced build_qemu_argv via dynamic scope)
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd qemu-system-x86_64

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"

# shellcheck disable=SC1090
source "$LAB_VM"

# ── firmware_for: bios → empty; uefi → an OVMF path ─────────────────────────
note "firmware_for x86_64 bios → empty (→ SeaBIOS)"
fw="$(firmware_for x86_64 false false bios)"
[[ -z "$fw" ]] || fail "bios mode must yield empty firmware (got: '$fw')"

note "firmware_for x86_64 uefi → an OVMF blob (if present on host)"
fw_uefi="$(firmware_for x86_64 false false uefi 2>/dev/null || true)"
if [[ -n "$fw_uefi" ]]; then
    [[ "$fw_uefi" == *[Oo][Vv][Mm][Ff]* ]] || fail "uefi firmware should be OVMF-ish: $fw_uefi"
    note "  uefi → $fw_uefi"
else
    note "  (no OVMF on host — skipping the uefi-path resolution assert)"
fi

# ── build_qemu_argv consequence: empty firmware = no pflash; a path = pflash ─
render_fw() {
    name=fwtest arch=x86_64 microvm=false accel=tcg cpus=1 memory=256M \
        kernel="" initrd="" append="" seed="" mac="" ssh_port=2222 \
        disk=/tmp/ipxe.qcow2 install_target=/tmp/target.qcow2 \
        pxe_dir="" pxe_bootfile="" firmware="$1"
    mkdir -p "$(vm_dir "$name")"
    build_qemu_argv
    printf '%s' "${QEMU_ARGV[*]}"
}
has() { grep -Fq -- "$2" <<<"$1"; }

note "bios (empty firmware) → no pflash, no -bios (uses default SeaBIOS)"
a="$(render_fw "")"
if has "$a" 'if=pflash'; then fail "bios mode leaked a pflash drive: $a"; fi
if has "$a" '-bios';     then fail "bios mode should not pass -bios: $a"; fi

note "uefi (firmware path) → -drive if=pflash"
a="$(render_fw "$tmp/OVMF_CODE.fd")"   # dummy path; build_qemu_argv just wires it as pflash
has "$a" 'if=pflash' || fail "uefi mode should emit a pflash drive: $a"

pass "firmware selector: bios → SeaBIOS (no pflash), uefi → OVMF pflash"
