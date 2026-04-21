#!/usr/bin/env bash
# Native amd64 Debian bookworm chroot. Hits the network.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq debootstrap

[[ "$(uname -m)" == "x86_64" ]] || skip "test assumes x86_64 host"
[[ -r /usr/share/keyrings/debian-archive-keyring.gpg ]] \
    || skip "missing debian-archive-keyring on host"

target="$(mktest_target debootstrap-amd64)"
name="ds-amd64-$$"
trap 'cleanup_target "$target" "$name"' EXIT

note "running debootstrap (this takes a minute)"
"$LAB_CHROOT" create \
    --backend debootstrap --distro debian --suite bookworm \
    --arch x86_64 --target "$target" --name "$name" \
    --variant minbase

[[ -r "${target}/etc/os-release" ]] || fail "no /etc/os-release in tree"
grep -q '^ID=debian' "${target}/etc/os-release" \
    || fail "/etc/os-release does not identify as debian"

note "exec test inside chroot"
"$LAB_CHROOT" enter "$name" -- /bin/true || fail "chroot enter+exec failed"

pass "native debootstrap produced a working bookworm chroot"
