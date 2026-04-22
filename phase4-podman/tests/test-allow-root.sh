#!/usr/bin/env bash
# Rootless-first gate: running as root without --allow-root must fail
# cleanly; with --allow-root it proceeds.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# If we're not root, we have to simulate.  Use `sudo -n` (non-interactive)
# so the test self-skips if sudo isn't passwordless.
if [[ $EUID -ne 0 ]]; then
    sudo -n true 2>/dev/null || skip "sudo -n not available; can't simulate root invocation"
    SUDO="sudo -n"
else
    SUDO=""
fi

# Without --allow-root: refuses.
out="$($SUDO env PATH="$PATH" "$LAB_PODMAN" list 2>&1 || true)"
grep -qi 'refusing to run as root' <<<"$out" \
    || fail "root invocation without --allow-root should have been refused; got: $out"
note "refusal OK"

# With --allow-root: at least advances past the rootless gate.  It may
# still fail later (no podman installed on the test host, etc.) — we
# only check that the refusal message is absent.
out="$($SUDO env PATH="$PATH" "$LAB_PODMAN" --allow-root help 2>&1 || true)"
if grep -qi 'refusing to run as root' <<<"$out"; then
    fail "--allow-root should have bypassed the refusal; got: $out"
fi
note "bypass OK"

pass "rootless-first gate behaves correctly"
