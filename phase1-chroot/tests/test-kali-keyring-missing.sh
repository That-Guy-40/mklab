#!/usr/bin/env bash
# When the Kali keyring is absent, the script must error out cleanly without
# touching the target directory.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq debootstrap

if [[ -r /usr/share/keyrings/kali-archive-keyring.gpg ]]; then
    skip "kali-archive-keyring is installed; cannot test the missing-keyring path"
fi

target="$(mktest_target kali-no-keyring)"
trap 'cleanup_target "$target" ""' EXIT

note "expecting failure with helpful error"
if "$LAB_CHROOT" create \
        --backend debootstrap --distro kali --suite kali-rolling \
        --arch x86_64 --target "$target" --name "kali-fail-$$" \
        2>&1 | tee /tmp/kali-no-keyring.$$.out; then
    rm -f /tmp/kali-no-keyring.$$.out
    fail "create succeeded but should have refused"
fi

grep -qi 'kali-archive-keyring' /tmp/kali-no-keyring.$$.out \
    || { rm -f /tmp/kali-no-keyring.$$.out; fail "error message did not mention kali-archive-keyring"; }
rm -f /tmp/kali-no-keyring.$$.out

# Crucial: target directory was created by the spec but should be empty
# (validation failed before any write into the tree).
if [[ -d "$target" ]]; then
    contents="$(ls -A "$target" 2>/dev/null || true)"
    [[ -z "$contents" ]] || fail "target was written into despite refusal: $contents"
fi

pass "missing kali-archive-keyring refused cleanly"
