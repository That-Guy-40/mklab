#!/usr/bin/env bash
# Unit test: the `tpm = true|false` selector wires an emulated TPM 2.0 into the
# QEMU argv — and ONLY when asked.
#   - tpm=true  → -chardev …chrtpm + -tpmdev emulator,id=tpm0 + a tpm-crb device.
#   - tpm=false → NONE of the above (REGRESSION guard: an ordinary VM must never
#     silently acquire a TPM, which would change its measured-boot surface).
#   - tpm unset → same as false.
# No QEMU boot, no swtpm process; sources lab-vm.sh and inspects QEMU_ARGV.

# shellcheck disable=SC2034  (globals consumed by sourced build_qemu_argv via dynamic scope)
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd qemu-system-x86_64

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"

# shellcheck disable=SC1090
source "$LAB_VM"

# Render build_qemu_argv with a given tpm value; return the flattened argv.
render_tpm() {
    name=tpmtest arch=x86_64 microvm=false accel=tcg cpus=1 memory=256M \
        kernel="" initrd="" append="" seed="" mac="" ssh_port=2222 \
        disk=/tmp/d.qcow2 install_target="" \
        pxe_dir="" pxe_bootfile="" firmware="" tpm="$1"
    mkdir -p "$(vm_dir "$name")"
    build_qemu_argv
    printf '%s' "${QEMU_ARGV[*]}"
}
has() { grep -Fq -- "$2" <<<"$1"; }

note "tpm=true → -tpmdev emulator + tpm-crb device + chrtpm chardev"
a="$(render_tpm true)"
has "$a" '-tpmdev'                  || fail "tpm=true must emit -tpmdev: $a"
has "$a" 'emulator,id=tpm0'         || fail "tpm=true must wire the emulator tpmdev: $a"
has "$a" 'tpm-crb,tpmdev=tpm0'      || fail "tpm=true must add the tpm-crb device (x86_64): $a"
has "$a" 'chrtpm'                   || fail "tpm=true must add the swtpm control chardev: $a"

note "tpm=false → NO tpm args at all (REGRESSION: a plain VM must not get a TPM)"
b="$(render_tpm false)"
if has "$b" 'tpmdev';  then fail "REGRESSION: tpm=false leaked a -tpmdev into the argv: $b"; fi
if has "$b" 'tpm-crb'; then fail "REGRESSION: tpm=false leaked a tpm-crb device into the argv: $b"; fi
if has "$b" 'chrtpm';  then fail "REGRESSION: tpm=false leaked the swtpm chardev into the argv: $b"; fi

note "tpm unset → treated as false (no tpm args)"
c="$(render_tpm "")"
if has "$c" 'tpmdev'; then fail "REGRESSION: unset tpm leaked a -tpmdev into the argv: $c"; fi

pass "tpm selector: true → emulated TPM 2.0 (crb) wired; false/unset → none"
