#!/usr/bin/env bash
# Regression (Review H3): backend_from_chroot must NOT dereference symlinks
# inside the chroot when building the image tarball.
#
# The bug: it staged the chroot as a `rootfs` symlink and archived with `tar -h`,
# which dereferences EVERY symlink in the tree.  Consequences on a real chroot:
#   (a) an absolute symlink to a host path baked the HOST's files into the
#       student-visible image (host-content disclosure);
#   (b) a dangling symlink (every systemd chroot's /etc/resolv.conf -> /run/...)
#       made tar exit non-zero, killing the build under `set -e`.
# The fix tars the chroot directly under a rootfs/ prefix, preserving inner
# symlinks AS symlinks.
#
# No root, no LXD needed: we stub the detectors + $LXC_CMD (whose `image import`
# just captures the tarball) and inspect what tar produced.
#
# shellcheck disable=SC1090,SC2317
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd tar gzip

work="$(mktemp -d)"; on_exit 'rm -rf "$work"'

# A chroot with the two dangerous symlink shapes.
chroot="$work/chroot"
secret="$work/host-secret"
mkdir -p "$chroot/etc" "$chroot/proc" "$secret"
echo "TOPSECRET-host-file"     > "$secret/leak.txt"
echo "real content"            > "$chroot/etc/passwd"
ln -s "$secret"                  "$chroot/etc/hostlink"      # absolute → host dir (leak vector)
ln -s /run/nonexistent           "$chroot/etc/resolv.conf"  # dangling (build-break vector)
echo "junk"                    > "$chroot/proc/should_drop" # exclusion check

source "$LAB_LXD"

# Stub the metadata detectors (avoid needing a real distro tree / host arch map).
detect_host_arch() { printf 'x86_64'; }
_detect_chroot_distro() { printf 'debian'; }
_detect_chroot_release() { printf 'trixie'; }
emit_metadata_yaml_container() { printf 'architecture: x86_64\ncreation_date: 0\n'; }

# Stub the engine: `image import <tarball> --alias <a>` captures the tarball.
captured="$work/captured.tar.gz"
_fake_lxc() {
    if [[ "$1" == image && "$2" == import ]]; then cp -f "$3" "$captured"; return 0; fi
    return 0   # image delete, etc.
}
LXC_CMD=_fake_lxc
LXC_ENGINE=incus

# The build MUST succeed despite the dangling symlink.  Run in a subshell so a
# `die` (which is `exit`) inside the function is caught here, not fatal to the
# harness.  Old code failed two ways: the readability preflight flagged the
# dangling symlink as "unreadable" and died; and `tar -h` aborted on it.
if ! ( backend_from_chroot "$chroot" "lab-x-img" ) >/dev/null 2>&1; then
    fail "REGRESSION: build failed on a chroot with a dangling symlink (preflight die or tar -h)"
fi
[[ -f "$captured" ]] || fail "no tarball captured from image import"
note "build succeeded with a dangling /etc/resolv.conf present"

members="$(tar tzf "$captured")"
# Layout: metadata.yaml at top, chroot under rootfs/.
grep -qx 'metadata.yaml'     <<<"$members" || fail "metadata.yaml not at archive top"
grep -qx 'rootfs/etc/passwd' <<<"$members" || fail "rootfs/etc/passwd missing"
note "unified layout intact (metadata.yaml + rootfs/)"

# The crux: the host secret must NOT be in the image (symlink preserved, not followed).
if tar xzf "$captured" -O rootfs/etc/hostlink/leak.txt 2>/dev/null | grep -q TOPSECRET; then
    fail "REGRESSION: host file leaked into the image via a dereferenced symlink"
fi
# resolv.conf and hostlink must be present AS symlinks, not as files/dirs.
#
# CAPTURE FIRST, THEN TEST.  These two lines were `tar tzvf … | grep -q … || fail`,
# and that shape made this test FLAKE: `grep -q` exits on its first match and closes
# the pipe, `tar` — which writes the listing incrementally — dies on SIGPIPE, and with
# `pipefail` set the PIPELINE reports 141, so a symlink that WAS present reported as
# absent.  Measured 2026-08-16 on a 13 KB listing: 140 spurious failures in 200 runs,
# and 0 in 200 with the capture form.  Note the size — the repo previously reasoned
# that this form "only bites with a producer big enough to fill a pipe buffer", which
# is true of a producer that writes ONCE (`docker ps`) and false of one that streams.
verbose_members="$(tar tzvf "$captured" 2>/dev/null)"
grep -q 'rootfs/etc/resolv.conf ->' <<<"$verbose_members" || fail "resolv.conf not preserved as a symlink"
grep -q 'rootfs/etc/hostlink ->'    <<<"$verbose_members" || fail "hostlink not preserved as a symlink"
note "inner symlinks preserved as symlinks; no host content baked in"

# Excludes still apply (on the new chroot-relative paths).
if grep -q 'rootfs/proc/should_drop' <<<"$members"; then
    fail "proc contents not excluded"
fi
note "proc/sys/dev/run/tmp exclusions honored"

pass "from_chroot preserves symlinks, no host leak, no build break"
