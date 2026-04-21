#!/usr/bin/env bash
# Rocky armv7l is unsupported upstream — the script must error before doing
# anything.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_root
require_cmd jq

target="$(mktest_target rocky-armv7l)"
trap 'cleanup_target "$target" ""' EXIT

note "expecting failure with helpful error"
if "$LAB_CHROOT" create \
        --backend dnf --distro rocky --suite 9 \
        --arch armv7l --target "$target" --name "rocky-armv7l-fail-$$" \
        2>&1 | tee /tmp/rocky-armv7l.$$.out; then
    rm -f /tmp/rocky-armv7l.$$.out
    fail "create succeeded but should have refused"
fi

grep -qi 'armv7l' /tmp/rocky-armv7l.$$.out \
    || { rm -f /tmp/rocky-armv7l.$$.out; fail "error did not mention the unsupported arch"; }
rm -f /tmp/rocky-armv7l.$$.out

if [[ -d "$target" ]]; then
    contents="$(ls -A "$target" 2>/dev/null || true)"
    [[ -z "$contents" ]] || fail "target was written into despite refusal: $contents"
fi

pass "Rocky armv7l rejected cleanly"
