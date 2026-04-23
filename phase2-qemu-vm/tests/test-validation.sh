#!/usr/bin/env bash
# Validation guardrails — fast tests that don't actually launch QEMU.

set -uo pipefail   # NOT -e: we expect the script to exit non-zero on bad input
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

# expect_error LABEL PATTERN -- ARGS...
expect_error() {
    local label="$1" pattern="$2"; shift 2
    [[ "$1" == "--" ]] && shift
    local out rc
    out="$("$LAB_VM" "$@" 2>&1)" && rc=0 || rc=$?
    if (( rc == 0 )); then
        fail "$label — expected non-zero exit, got 0; output: $out"
    fi
    if ! grep -qi -- "$pattern" <<<"$out"; then
        fail "$label — error message did not match /$pattern/i; got: $out"
    fi
    note "$label OK"
}

expect_error "unknown backend"        "unknown backend"     -- create --name x --backend bogus --arch x86_64
expect_error "unknown arch"           "unknown arch"        -- create --name x --arch m68k --distro debian --suite bookworm
expect_error "missing kernel/initrd"  "not readable"        -- create --name x --backend kernel+initrd --arch x86_64 --kernel /tmp/nope-vmlinuz --initrd /tmp/nope-initrd
expect_error "from-chroot needs chroot" "requires a chroot field" -- create --name x --backend from-chroot --arch x86_64
expect_error "disk-image bare"        "needs either image"  -- create --name x --backend disk-image --arch x86_64

pass "validation guardrails OK"
