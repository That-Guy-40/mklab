#!/usr/bin/env bash
# Build a host-copy chroot, register with schroot, round-trip enter, destroy.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq schroot ldd

target="$(mktest_target schroot)"
name="sc-test-$$"
trap 'cleanup_target "$target" "$name"' EXIT

probe="/bin/busybox"; [[ -x "$probe" ]] || probe="/bin/ls"

"$LAB_CHROOT" create \
    --backend host-copy --target "$target" --name "$name" \
    --binaries "$probe" --manager schroot

[[ -r "/etc/schroot/chroot.d/${name}.conf" ]] \
    || fail "schroot conf was not written"

schroot -l 2>/dev/null | grep -q "chroot:${name}" \
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
