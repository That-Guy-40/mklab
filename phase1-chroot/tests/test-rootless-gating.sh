#!/usr/bin/env bash
# Unit test: --rootless gating.  The config constraints (backend/manager/arch)
# are rejected with clear errors before the tool checks for fakechroot/fakeroot;
# a valid combo then requires those tools.  No root, nothing is built — every
# case dies during validation.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq

export LAB_STATE_DIR; LAB_STATE_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$LAB_STATE_DIR'" EXIT
host_arch="$(uname -m)"

run() { "$LAB_CHROOT" create --rootless "$@" 2>&1 || true; }

# dnf backend → rejected (needs root)
out="$(run --backend dnf --distro rocky --suite 9 --arch "$host_arch" --target /srv/r1 --name r1)"
grep -qi 'rootless supports backend' <<<"$out" || fail "dnf + --rootless not rejected: $out"
note "rootless + dnf rejected"

# schroot manager → rejected
out="$(run --backend debootstrap --distro debian --suite bookworm --arch "$host_arch" --manager schroot --target /srv/r2 --name r2)"
grep -qi 'rootless requires manager=none' <<<"$out" || fail "schroot + --rootless not rejected: $out"
note "rootless + manager=schroot rejected"

# foreign arch → rejected
foreign=aarch64; case "$host_arch" in aarch64|arm64) foreign=x86_64 ;; esac
out="$(run --backend debootstrap --distro debian --suite bookworm --arch "$foreign" --target /srv/r3 --name r3)"
grep -qi 'native-arch only' <<<"$out" || fail "foreign-arch + --rootless not rejected: $out"
note "rootless + foreign arch rejected"

# valid combo → passes gating, then requires fakechroot + fakeroot
out="$(run --backend debootstrap --distro debian --suite bookworm --arch "$host_arch" --target /srv/r4 --name r4)"
if command -v fakechroot >/dev/null 2>&1 && command -v fakeroot >/dev/null 2>&1; then
    note "fakechroot+fakeroot present — valid combo cleared gating (would proceed to build)"
else
    grep -qiE 'fakechroot|fakeroot|not found' <<<"$out" \
        || fail "valid rootless combo should require fakechroot/fakeroot: $out"
    note "valid combo gated on missing fakechroot/fakeroot"
fi

pass "--rootless gating OK"
