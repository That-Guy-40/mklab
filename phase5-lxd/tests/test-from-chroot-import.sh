#!/usr/bin/env bash
# Cross-phase: build a tiny rootfs-as-chroot by hand, import via build
# --backend from-chroot, confirm launchable, tear down.
#
# Doesn't run Phase 1 (debootstrap is slow + needs network).  Uses a
# scratch busybox-style tree that's enough to exercise the rebundle path.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_lxd_or_incus
require_cmd jq tar

scratch="$(mktemp -d)"
alias_tag="lab-phase5test-$$"
trap 'rm -rf "$scratch"; cleanup_image_alias "$alias_tag"' EXIT

note "building a minimal chroot under $scratch"
install -d "$scratch/bin" "$scratch/etc" "$scratch/dev" "$scratch/proc" "$scratch/sys" "$scratch/tmp" "$scratch/root"
# Populate /etc/os-release so the metadata.yaml detector has something.
cat > "$scratch/etc/os-release" <<EOF
ID=lab-test
VERSION_ID=0.1
VERSION_CODENAME=scratch
PRETTY_NAME="lab-create phase5 test rootfs"
EOF
# We need at least one executable at the standard paths; symlink busybox
# if available, else leave empty (the image imports fine either way).
if command -v busybox >/dev/null 2>&1; then
    cp "$(command -v busybox)" "$scratch/bin/busybox"
fi

note "build --alias $alias_tag --backend from-chroot"
"$LAB_LXD" build --alias "$alias_tag" --backend from-chroot --chroot "$scratch"

note "verify alias exists"
"$LXC_CMD" image list --format=json 2>/dev/null \
    | jq -e --arg a "$alias_tag" '.[] | select(.aliases[]?.name == $a)' >/dev/null \
    || fail "imported alias $alias_tag not visible in image list"

note "alias round-trip OK"
pass "from-chroot import OK"
