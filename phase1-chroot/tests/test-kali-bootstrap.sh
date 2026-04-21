#!/usr/bin/env bash
# Native Kali rolling chroot via debootstrap.  Hits the network.
#
# Skips cleanly if the host doesn't have kali-archive-keyring installed —
# the missing-keyring case is exercised by test-kali-keyring-missing.sh
# instead.  Together the two tests cover both branches of
# debootstrap_keyring_for() for the kali distro.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq debootstrap

[[ "$(uname -m)" == "x86_64" ]] || skip "test assumes x86_64 host"
[[ -r /usr/share/keyrings/kali-archive-keyring.gpg ]] \
    || skip "missing /usr/share/keyrings/kali-archive-keyring.gpg on host"

target="$(mktest_target kali-bootstrap)"
name="kali-$$"
trap 'cleanup_target "$target" "$name"' EXIT

note "running debootstrap kali-rolling (this takes 1–3 min)"
"$LAB_CHROOT" create \
    --backend debootstrap --distro kali --suite kali-rolling \
    --arch x86_64 --target "$target" --name "$name" \
    --variant minbase

# /etc/os-release identity check.  Kali derives from Debian and sets
# ID=kali, ID_LIKE=debian.  Accept either spelling for forwards-compat
# in case Kali ever ships with quoted values.
[[ -r "${target}/etc/os-release" ]] || fail "no /etc/os-release in tree"
grep -Eq '^ID="?kali"?$' "${target}/etc/os-release" \
    || fail "/etc/os-release does not identify as kali"
grep -Eq '^ID_LIKE=.*debian' "${target}/etc/os-release" \
    || note "warning: ID_LIKE doesn't mention debian — Kali may have changed packaging"

# Kali ships its own apt sources.list pointing at http.kali.org.
# Confirm that landed so the chroot is actually self-extensible with apt.
if [[ -r "${target}/etc/apt/sources.list" ]]; then
    grep -q 'kali' "${target}/etc/apt/sources.list" \
        || fail "/etc/apt/sources.list doesn't reference a kali mirror"
elif compgen -G "${target}/etc/apt/sources.list.d/*.list" >/dev/null; then
    grep -qrE 'kali' "${target}/etc/apt/sources.list.d/" \
        || fail "no kali repo line in /etc/apt/sources.list.d/"
else
    fail "no apt sources.list (or .list.d/*.list) in chroot"
fi

note "verify subcommand"
"$LAB_CHROOT" verify "$name" >/dev/null

note "exec test inside chroot"
"$LAB_CHROOT" enter "$name" -- /bin/true || fail "chroot enter+exec failed"

# Spot-check that the kali keyring was copied/configured inside the tree
# (debootstrap installs the matching keyring package in the chroot when
# the distro is kali; without it, in-chroot apt operations would fail).
"$LAB_CHROOT" enter "$name" -- /usr/bin/dpkg -l kali-archive-keyring >/dev/null 2>&1 \
    || note "warning: kali-archive-keyring not visible in chroot's dpkg db (apt-get update may warn)"

pass "native debootstrap produced a working kali-rolling chroot"
