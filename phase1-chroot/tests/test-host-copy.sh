#!/usr/bin/env bash
# Build a host-copy chroot containing /bin/busybox (or /bin/ls as fallback)
# and exec a command inside it. No network, fastest possible smoke test.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq ldd

probe_bin=""
for cand in /bin/busybox /usr/bin/busybox /bin/ls; do
    if [[ -x "$cand" ]]; then probe_bin="$cand"; break; fi
done
[[ -n "$probe_bin" ]] || skip "no probe binary on host"

target="$(mktest_target host-copy)"
name="hc-test-$$"
trap 'cleanup_target "$target" "$name"' EXIT

note "creating host-copy chroot at $target with $probe_bin"
"$LAB_CHROOT" create \
    --backend host-copy \
    --target "$target" \
    --name "$name" \
    --binaries "$probe_bin"

[[ -x "${target}${probe_bin}" ]] || fail "binary not copied"

# Loader presence is required for the chroot to actually exec a *dynamic*
# binary.  Static binaries (e.g. busybox on Debian/Ubuntu) need zero libs,
# so don't insist on /lib* in that case — the regression test
# test-host-copy-static-binary.sh covers the static path explicitly.
if ldd "$probe_bin" >/dev/null 2>&1; then
    ls "${target}/lib"* "${target}/lib64" 2>/dev/null | grep -q . \
        || fail "no libs copied (chroot would be unable to exec dynamic $probe_bin)"
else
    note "$probe_bin is statically linked — skipping lib-presence check"
fi

note "exec'ing $probe_bin inside chroot"
chroot "$target" "$probe_bin" --help >/dev/null 2>&1 \
    || chroot "$target" "$probe_bin" / >/dev/null 2>&1 \
    || fail "chroot exec failed"

note "verify subcommand"
"$LAB_CHROOT" verify "$name" >/dev/null

pass "host-copy backend produced a working chroot"
