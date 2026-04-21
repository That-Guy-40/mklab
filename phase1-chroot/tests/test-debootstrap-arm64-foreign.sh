#!/usr/bin/env bash
# Foreign-arch debootstrap: aarch64 Debian bookworm on whatever host.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq debootstrap qemu-aarch64-static
[[ -r /usr/share/keyrings/debian-archive-keyring.gpg ]] \
    || skip "missing debian-archive-keyring on host"

if [[ "$(uname -m)" == "aarch64" ]]; then
    skip "host is already aarch64; this test exercises the foreign path"
fi

if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    skip "binfmt qemu-aarch64 not registered (try: sudo update-binfmts --enable qemu-aarch64)"
fi

target="$(mktest_target deboot-arm64)"
name="ds-arm64-$$"
trap 'cleanup_target "$target" "$name"' EXIT

note "running 2-stage debootstrap aarch64 (this takes several minutes)"
"$LAB_CHROOT" create \
    --backend debootstrap --distro debian --suite bookworm \
    --arch aarch64 --target "$target" --name "$name" \
    --variant minbase

[[ -x "${target}/usr/bin/qemu-aarch64-static" ]] \
    || fail "qemu-aarch64-static not present in tree"

inside="$(chroot "$target" /usr/bin/uname -m 2>/dev/null || true)"
[[ "$inside" == "aarch64" ]] || fail "uname inside chroot returned '$inside', expected aarch64"

pass "foreign aarch64 debootstrap produced an aarch64-reporting chroot"
