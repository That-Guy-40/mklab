#!/usr/bin/env bash
# Unit test: pod-mode auto-build wiring — confirms the v0.1 "needs an image"
# gate was removed and that from_chroot / from_tarball / build code paths are
# wired into the pod service start loop.
#
# All assertions are static (source inspection), not live podman calls, so
# this test is network-free and doesn't need a running daemon.

set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# ── (1) Old die guard is gone ───────────────────────────────────────────────
note "checking removal of v0.1 'needs an image' die guard"
if grep -q "needs an image (no auto-build in pod mode v0.1)" "$LAB_PODMAN"; then
    fail "stale v0.1 die guard is still present — pod auto-build not wired"
fi
note "v0.1 die guard removed"

# ── (2) Pod service loop now has the image-resolution block ─────────────────
# Extract the start_services_in_pod function (the pod inner loop).
note "image-resolution block present in pod service start loop"
pod_loop_src="$(awk '/^start_services_in_pod\(\)/,/^}/' "$LAB_PODMAN")"

grep -q 'from_tarball'          <<<"$pod_loop_src" || fail "pod loop missing from_tarball branch"
grep -q 'from_chroot'           <<<"$pod_loop_src" || fail "pod loop missing from_chroot branch"
grep -q 'backend_from_tarball'  <<<"$pod_loop_src" || fail "pod loop doesn't call backend_from_tarball"
grep -q 'backend_from_chroot'   <<<"$pod_loop_src" || fail "pod loop doesn't call backend_from_chroot"
grep -q 'backend_build'         <<<"$pod_loop_src" || fail "pod loop doesn't call backend_build"
note "all three image backends wired into pod mode"

# ── (3) The mutually-exclusive guard is present ──────────────────────────────
grep -q 'from_tarball and from_chroot are mutually exclusive' \
    <<<"$pod_loop_src" \
    || fail "mutual-exclusion guard missing from pod loop"
note "from_tarball/from_chroot mutually-exclusive guard present"

# ── (4) Plain-mode image resolution still intact (no regression) ─────────────
note "plain-mode image resolution unchanged"
plain_src="$(awk '/^start_service_plain\(\)/,/^}/' "$LAB_PODMAN")"
grep -q 'backend_from_tarball'  <<<"$plain_src" || fail "plain mode lost backend_from_tarball"
grep -q 'backend_from_chroot'   <<<"$plain_src" || fail "plain mode lost backend_from_chroot"
grep -q 'backend_build'         <<<"$plain_src" || fail "plain mode lost backend_build"
note "plain-mode image resolution intact"

pass "pod auto-build wiring OK (from_chroot / from_tarball / build in pod mode)"
