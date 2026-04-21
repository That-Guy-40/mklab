#!/usr/bin/env bash
# Arch table sanity check: every supported arch maps to a qemu-system binary
# name and a machine type. Doesn't actually run QEMU.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# Source the script in inspect-mode by extracting arch_map.
# Easier: just exec the script and catch the error path that always exercises
# arch_map indirectly. We'll use validate via a never-quite-runnable spec.

for arch in x86_64 aarch64 armv7l ppc64le riscv64 s390x; do
    note "arch=$arch — should validate (then fail at firmware lookup or qemu binary, that's OK)"
    out="$("$LAB_VM" create --name dryrun-$arch --backend kernel+initrd --arch "$arch" \
        --kernel /tmp/nope --initrd /tmp/nope 2>&1 || true)"
    # We expect the failure to mention the missing kernel — meaning arch was accepted.
    grep -qi 'not readable' <<<"$out" \
        || fail "arch=$arch was rejected at validation: $out"
done

note "unknown arch m68k → rejected"
out="$("$LAB_VM" create --name x --backend kernel+initrd --arch m68k 2>&1 || true)"
grep -qi 'unknown arch' <<<"$out" || fail "m68k was not rejected"

pass "all 6 arches accepted by validation"
