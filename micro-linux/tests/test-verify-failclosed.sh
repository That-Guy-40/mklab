#!/usr/bin/env bash
# §6.0/§8: verification is fail-closed — it refuses an unpinned fingerprint and
# a missing keyring rather than trusting a fetched checksum.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
source "$MLBUILD"
set +e

# versions.env parses and defines the required pins
( set -e; source "$TEST_DIR/../versions.env"; : "${LINUX_VER:?}" "${BUSYBOX_VER:?}" "${UROOT_REF:?}" ) \
    || fail "versions.env must define LINUX_VER, BUSYBOX_VER, UROOT_REF"
note "versions.env defines LINUX_VER/BUSYBOX_VER/UROOT_REF"

# informational: is the shipped fingerprint still the fail-closed placeholder?
if ( set -e; source "$TEST_DIR/../versions.env"; case "$KERNEL_FPR" in PIN-ME*) exit 0;; *) exit 1;; esac ); then
    note "shipped KERNEL_FPR is the fail-closed placeholder (vendor a real key before building)"
else
    note "KERNEL_FPR appears pinned to a real fingerprint"
fi

if have gpg; then
    KR="$TEST_DIR/../keys/kernel.gpg"
    if [[ -r "$KR" ]]; then
        # positive: the vendored keyring satisfies the pinned fingerprints
        ( set -e; source "$TEST_DIR/../versions.env"; assert_keyring_fpr "$KR" "$KERNEL_FPR" kernel ) >/dev/null 2>&1 \
            && note "vendored keys/kernel.gpg matches pinned KERNEL_FPR" \
            || fail "assert_keyring_fpr should ACCEPT the vendored kernel keyring + pinned fpr"
        # negative: an unpinned sentinel is refused even with a populated keyring
        ( assert_keyring_fpr "$KR" "PIN-ME-foo" t ) >/dev/null 2>&1 \
            && fail "must refuse the PIN-ME sentinel" || note "refuses an unpinned (PIN-ME) fingerprint"
        # negative: a fingerprint absent from the keyring is refused
        ( assert_keyring_fpr "$KR" "0000000000000000000000000000000000000000" t ) >/dev/null 2>&1 \
            && fail "must refuse a fingerprint absent from the keyring" || note "refuses an absent fingerprint"
    else
        note "keys/kernel.gpg not vendored yet — positive keyring check skipped"
    fi
    # negative: a missing keyring file is refused
    ( assert_keyring_fpr /no/such/keyring.gpg x t ) >/dev/null 2>&1 \
        && fail "must refuse a missing keyring" || note "refuses a missing keyring"
else
    note "gpg not installed — keyring-assertion checks skipped"
fi

pass "verification is fail-closed OK"
