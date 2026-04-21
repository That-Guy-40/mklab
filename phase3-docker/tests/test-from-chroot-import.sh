#!/usr/bin/env bash
# Build a tiny chroot via tar, import into docker, run.
# We avoid depending on Phase 1 here so the test stays self-contained.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_docker
require_cmd tar ldd

probe="/bin/busybox"; [[ -x "$probe" ]] || probe="/bin/ls"
[[ -x "$probe" ]] || skip "no probe binary on host"

chroot_dir="$(mktemp -d)"
tag="lab-from-chroot-test-$$:lab"
name="t-fcimport-$$"
cname="lab-${name}"

cleanup() {
    cleanup_container "$cname"
    docker rmi "$tag" >/dev/null 2>&1 || true
    rm -rf "$chroot_dir"
}
trap cleanup EXIT

note "building minimal chroot at $chroot_dir"
# Resolve the binary + libs via ldd; mirror the Phase-1 host-copy logic.
{
    printf '%s\n' "$probe"
    # Same defensive pattern as phase1: ldd exits non-zero on static
    # binaries, which pipefail would propagate and kill the script silently.
    { ldd "$probe" 2>/dev/null || true; } | awk '
        /linux-vdso/ { next }
        /not a dynamic/ { next }
        /statically linked/ { next }
        $2 == "=>" && $3 ~ /^\// { print $3; next }
        $1 ~ /^\//                { print $1; next }
    '
} | sort -u | while read -r p; do
    [[ -n "$p" ]] && cp --parents -L --preserve=mode "$p" "$chroot_dir/" 2>/dev/null
done
mkdir -p "$chroot_dir"/{proc,sys,dev,tmp,run,etc}

note "import → $tag"
"$LAB_DOCKER" build --tag "$tag" --backend from-chroot --chroot "$chroot_dir"

docker images "$tag" --format '{{.Repository}}:{{.Tag}}' | grep -qx "$tag" \
    || fail "image $tag not present after import"

note "run + verify exec"
got="$("$LAB_DOCKER" run --name "$name" --image "$tag" --rm --tty -- "$probe" --help 2>&1 \
       || "$LAB_DOCKER" run --name "$name" --image "$tag" --rm --tty -- "$probe" / 2>&1)"
# Just check the container ran without imploding.
[[ -n "$got" ]] || fail "ran but produced no output"

pass "from-chroot import + run OK"
