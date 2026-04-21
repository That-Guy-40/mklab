#!/usr/bin/env bash
# Build a host-copy chroot, register under /var/lib/machines/, exec via nspawn.
# We don't test boot=true here (needs a full systemd in-tree → covered by
# debootstrap + manager=nspawn manual integration runs).

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq systemd-nspawn machinectl

target="$(mktest_target nspawn)"
name="ns-test-$$"
trap 'cleanup_target "$target" "$name"' EXIT

probe="/bin/busybox"; [[ -x "$probe" ]] || probe="/bin/ls"

"$LAB_CHROOT" create \
    --backend host-copy --target "$target" --name "$name" \
    --binaries "$probe" --manager nspawn

[[ -L "/var/lib/machines/${name}" ]] \
    || fail "machinectl symlink not created"

machinectl list-images --no-pager 2>/dev/null | grep -q "$name" \
    || fail "machinectl list-images does not show our chroot"

note "systemd-nspawn -D $target -- $probe"
systemd-nspawn --quiet -D "$target" -- "$probe" --help >/dev/null 2>&1 \
    || systemd-nspawn --quiet -D "$target" -- "$probe" / >/dev/null 2>&1 \
    || fail "systemd-nspawn exec failed"

"$LAB_CHROOT" destroy "$name" --force
[[ ! -e "/var/lib/machines/${name}" ]] \
    || fail "machinectl symlink not cleaned up by destroy"

pass "nspawn round-trip OK"
