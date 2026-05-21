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
    ( assert_keyring_fpr /dev/null "PIN-ME-foo" t ) >/dev/null 2>&1 \
        && fail "assert_keyring_fpr must refuse the PIN-ME sentinel" \
        || note "refuses an unpinned (PIN-ME) fingerprint"
    ( assert_keyring_fpr /no/such/keyring.gpg "DEADBEEF" t ) >/dev/null 2>&1 \
        && fail "assert_keyring_fpr must refuse a missing keyring" \
        || note "refuses a missing keyring"
else
    note "gpg not installed — keyring-assertion checks skipped"
fi

pass "verification is fail-closed OK"
