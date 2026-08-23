#!/usr/bin/env bash
# Build a host-copy chroot, register with schroot, round-trip enter, destroy.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq schroot ldd

target="$(mktest_target schroot)"
name="sc-test-$$"
on_exit 'cleanup_target "$target" "$name"'

probe="/bin/busybox"; [[ -x "$probe" ]] || probe="/bin/ls"

"$LAB_CHROOT" create \
    --backend host-copy --target "$target" --name "$name" \
    --binaries "$probe" --manager schroot

[[ -r "/etc/schroot/chroot.d/${name}.conf" ]] \
    || fail "schroot conf was not written"

# Capture, then test: a verdict must not hang off a pipe into `grep -q` (it exits on the
# first match, the producer can take SIGPIPE, and with pipefail the pipeline is non-zero,
# so a match that WAS found reads as absent). Invisible to tools/tests/test-no-pipe-gates.sh
# until 2026-08-22, because that scanner read PHYSICAL lines and this gate spans a
# backslash continuation. `|| true` keeps the capture from tripping errexit where it is set.
_schroots="$(schroot -l 2>/dev/null || true)"
grep -q "chroot:${name}" <<<"$_schroots" \
    || fail "schroot -l does not list our chroot"

note "schroot -c $name --directory / -- $probe"
# --directory / is required when invoking schroot directly because schroot
# would otherwise chdir to the test's CWD inside the chroot (which doesn't
# exist there). Our `enter` wrapper passes this flag automatically.
schroot -c "$name" --directory / -- "$probe" --help >/dev/null 2>&1 \
    || schroot -c "$name" --directory / -- "$probe" / >/dev/null 2>&1 \
    || fail "schroot exec failed"

"$LAB_CHROOT" destroy "$name" --force
[[ ! -e "/etc/schroot/chroot.d/${name}.conf" ]] \
    || fail "schroot conf was not cleaned up by destroy"

pass "schroot round-trip OK"
