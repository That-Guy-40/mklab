#!/usr/bin/env bash
# Regression (Review H2): backend_vm_from_chroot must release its loop device
# and remove the partial output when a build step FAILS mid-way.
#
# The bug: cleanup was a RETURN trap, but every error path is `|| die` and `die`
# is `exit` — which does NOT run a RETURN trap — so an aborted build leaked a
# root-owned /dev/loopN and a live mount every time.  The fix runs the work in a
# subshell with an EXIT trap (fires on `die`).
#
# We let losetup/parted run for REAL (root), then force a failure at mkfs.ext4
# via a PATH shim, and assert the loop device was detached and the partials
# removed.  losetup detach is exactly the leak the RETURN trap missed.
#
# shellcheck disable=SC1090,SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
[[ "${EUID:-$(id -u)}" -eq 0 ]] || skip "needs root (loop mounts)"
require_cmd qemu-img parted losetup extlinux rsync blkid dd

# mkfs.ext4 must exist for the real require_cmd inside the function to pass,
# even though our shim shadows it on PATH.
command -v mkfs.ext4 >/dev/null 2>&1 || skip "missing required command: mkfs.ext4"
# The MBR blob is probed before any loop work; skip cleanly if syslinux absent.
_have_mbr=""
for p in /usr/lib/syslinux/mbr/mbr.bin /usr/share/syslinux/mbr.bin \
         /usr/lib/syslinux/mbr.bin /usr/lib/extlinux/mbr.bin; do
    [[ -r "$p" ]] && { _have_mbr=1; break; }
done
[[ -n "$_have_mbr" ]] || skip "syslinux mbr.bin not installed"

work="$(mktemp -d)"
# Safety net: detach any loop bound to our raw + unmount stragglers, even if the
# code-under-test regressed and leaked them; and always print a clear FAIL if the
# test exits early (uncaught `die`/`set -e`) so the terminal is never silent.
cleanup() {
    local rc=$?
    local d
    for d in $(losetup -j "$work/out.qcow2.raw.partial" -O NAME --noheadings 2>/dev/null); do
        losetup -d "$d" 2>/dev/null || true
    done
    rm -rf -- "$work"
    (( rc == 0 || rc == 77 )) || printf 'FAIL: test exited early (rc=%s) — see messages above\n' "$rc" >&2
}
trap cleanup EXIT

# A fake chroot under the required LAB_STATE_DIR/chroots location, with the
# kernel + initrd the backend expects to find.
export LAB_STATE_DIR="$work/state" LAB_CACHE_DIR="$work/cache"
chroot="$LAB_STATE_DIR/chroots/h2"
mkdir -p "$chroot/boot"
: > "$chroot/boot/vmlinuz-1-test"
: > "$chroot/boot/initrd.img-1-test"

# PATH shim: mkfs.ext4 fails, forcing `die` right AFTER losetup succeeds — the
# exact window where the old RETURN trap leaked the loop device.
shim="$work/shim"; mkdir -p "$shim"
cat > "$shim/mkfs.ext4" <<'EOF'
#!/usr/bin/env bash
echo "shim mkfs.ext4: forced failure for H2 regression" >&2
exit 1
EOF
chmod +x "$shim/mkfs.ext4"
export PATH="$shim:$PATH"

source "$LAB_VM"

out="$work/out.qcow2"
# The build MUST fail (mkfs shim).  Run in a subshell: backend_vm_from_chroot
# reports failure via `die` (=exit), which would otherwise kill this test before
# the assertions run.  The subshell contains the exit; a non-zero result is
# expected here.
if ( backend_vm_from_chroot "$chroot" "$out" 64M ) >/dev/null 2>&1; then
    fail "backend_vm_from_chroot returned success despite forced mkfs failure"
fi
note "build aborted at mkfs.ext4 as intended"

# The crux: no loop device may remain bound to the raw image.
raw="${out}.raw.partial"
leaked="$(losetup -j "$raw" -O NAME --noheadings 2>/dev/null || true)"
[[ -z "$leaked" ]] || fail "REGRESSION: leaked loop device(s) after failed build: $leaked"
note "loop device released by the cleanup trap"

# And the partial artifacts must be gone (trap's rm -f).
[[ ! -e "$raw" ]] || fail "partial raw image left behind: $raw"
[[ ! -e "$out" ]] || fail "partial output qcow2 left behind: $out"
note "partial raw + output removed"

pass "from-chroot cleanup trap fires on mid-build failure (no leaked loop/mount)"
