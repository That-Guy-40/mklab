#!/usr/bin/env bash
# test-vm-spec.sh — the phase-2 spec that boots the root-on-ZFS disk must be
# wired for UEFI/OVMF (ZFSBootMenu is an EFI executable — it cannot boot under
# SeaBIOS/MBR the way this lab uses it).  Two layers:
#   (a) ALWAYS host-safe: parse zbm-debian.toml with tomllib and assert the
#       backend/firmware/cloud-init wiring.  Passes here.
#   (b) If qemu-system-x86_64 is present: source lab-vm.sh and assert its
#       argv builder emits an OVMF pflash + a virtio-blk boot disk.  Deferred
#       (noted, not failed) when qemu is absent — as on this host.
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
arm_exit_trap

require_cmd python3
python3 -c 'import tomllib' 2>/dev/null || skip "python3 tomllib not available (<3.11)"

SPEC="$LAB_DIR/zbm-debian.toml"
[[ -r "$SPEC" ]] || fail "zbm-debian.toml not found at $SPEC"

# (a) Structural validation of the spec — host-safe.
python3 - "$SPEC" <<'PY' || fail "zbm-debian.toml failed validation (see message above)"
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    try:
        doc = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        print(f"  - invalid TOML: {e}", file=sys.stderr); sys.exit(1)
vms = doc.get("vm")
if not isinstance(vms, list) or not vms:
    print("  - no [[vm]] table found", file=sys.stderr); sys.exit(1)
vm = vms[0]
def need(cond, msg):
    if not cond:
        print(f"  - {msg}", file=sys.stderr); sys.exit(1)
need(vm.get("name"), "[[vm]].name is required")
need(vm.get("backend") == "disk-image", "backend must be 'disk-image' (boots a hand-built qcow2)")
need(vm.get("firmware") == "uefi", "firmware must be 'uefi' — ZFSBootMenu is an EFI executable")
need(vm.get("cloud_init") is False, "cloud_init must be false — the ZFS image is not cloud-init driven")
img = vm.get("image", "")
need(isinstance(img, str) and img.startswith("/"),
     "image must be an ABSOLUTE path (lab-vm.sh uses it as a qcow2 backing file)")
print(f"  - spec ok: name={vm['name']} backend=disk-image firmware=uefi cloud_init=false", file=sys.stderr)
PY
note "zbm-debian.toml: UEFI disk-image spec is well-formed  ✓"

# (b) argv wiring — only when qemu is installed.
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"
    LAB_VM="$(cd -- "$LAB_DIR/../../phase2-qemu-vm" && pwd)/lab-vm.sh"
    [[ -r "$LAB_VM" ]] || fail "cannot locate phase2-qemu-vm/lab-vm.sh at $LAB_VM"
    # shellcheck disable=SC1090,SC2034
    source "$LAB_VM"
    fw="$(firmware_for x86_64 false false uefi 2>/dev/null || true)"
    [[ -n "$fw" ]] || note "(no OVMF blob on host; firmware path resolution skipped)"
    # shellcheck disable=SC2034
    render() {
        name=zbmtest arch=x86_64 microvm=false accel=tcg cpus=2 memory=2048M \
            kernel="" initrd="" append="" seed="" mac="" ssh_port=0 \
            disk="$tmp/root-on-zfs.qcow2" install_target="" \
            pxe_dir="" pxe_bootfile="" firmware="${fw:-$tmp/OVMF_CODE.fd}"
        mkdir -p "$(vm_dir "$name")"
        build_qemu_argv
        printf '%s' "${QEMU_ARGV[*]}"
    }
    a="$(render)"
    grep -Fq -- 'if=pflash' <<<"$a" || fail "UEFI spec did not emit an OVMF pflash drive"
    grep -Fq -- 'virtio-blk' <<<"$a" || fail "no virtio-blk boot disk in argv"
    note "lab-vm.sh argv: OVMF pflash + virtio-blk boot disk  ✓"
    pass "zbm-debian.toml validates and produces a correct OVMF/UEFI QEMU command line"
else
    note "qemu-system-x86_64 absent — argv-wiring assertion deferred to a KVM-capable host"
    pass "zbm-debian.toml is a well-formed UEFI disk-image spec (argv wiring deferred: no qemu here)"
fi
