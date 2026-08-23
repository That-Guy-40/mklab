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
on_exit 'cleanup_target "$target" "$name"'

probe="/bin/busybox"; [[ -x "$probe" ]] || probe="/bin/ls"

"$LAB_CHROOT" create \
    --backend host-copy --target "$target" --name "$name" \
    --binaries "$probe" --manager nspawn

[[ -L "/var/lib/machines/${name}" ]] \
    || fail "machinectl symlink not created"

# Capture, then test: a verdict must not hang off a pipe into `grep -q` (it exits on the
# first match, the producer can take SIGPIPE, and with pipefail the pipeline is non-zero,
# so a match that WAS found reads as absent). Invisible to tools/tests/test-no-pipe-gates.sh
# until 2026-08-22, because that scanner read PHYSICAL lines and this gate spans a
# backslash continuation. `|| true` keeps the capture from tripping errexit where it is set.
_images="$(machinectl list-images --no-pager 2>/dev/null || true)"
grep -q "$name" <<<"$_images" \
    || fail "machinectl list-images does not show our chroot"

note "systemd-nspawn -D $target -- $probe"
systemd-nspawn --quiet -D "$target" -- "$probe" --help >/dev/null 2>&1 \
    || systemd-nspawn --quiet -D "$target" -- "$probe" / >/dev/null 2>&1 \
    || fail "systemd-nspawn exec failed"

"$LAB_CHROOT" destroy "$name" --force
[[ ! -e "/var/lib/machines/${name}" ]] \
    || fail "machinectl symlink not cleaned up by destroy"

pass "nspawn round-trip OK"
