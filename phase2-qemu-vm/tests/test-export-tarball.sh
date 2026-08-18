#!/usr/bin/env bash
# Slice 7 / §9.5 tier 2 — the last of the four, and the one the plan called the gap.
#
# The other three phases were ALSO gaps; §9.5's table said otherwise because
# Appendix A measured "`export` verb present" when the question was "can this
# become a portable artifact". Phase 2 was at least honestly marked ⛔.
#
# ROOTLESS, WHICH WAS NOT OBVIOUS. libguestfs reads the disk through an appliance
# supermin builds — no loop mount, no qemu-nbd, no sudo. The only blocker on
# Debian/Ubuntu is that /boot/vmlinuz-* is 0600 while /lib/modules/ is not, so
# `SUPERMIN_KERNEL` + `SUPERMIN_MODULES` pointed at a readable copy is the whole
# fix, and the driver finds that copy itself. Where neither is available this
# test SKIPs with the exact command that fixes it — an unmet precondition is an
# UNKNOWN, not a pass.
#
# The fixture is built here rather than downloaded: mke2fs -d needs no root and
# no network, and it produces exactly the shape phase 2's kernel+initrd and
# from-chroot VMs have — a BARE filesystem with no partition table and no
# inspectable OS, which is the case libguestfs `-i` alone cannot handle.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd guestfish
require_cmd mke2fs
require_cmd qemu-img

KVER="$(uname -r)"
KCOPY="${MKLAB_SUPERMIN_KERNEL:-$HOME/.cache/mklab-kernel/vmlinuz}"
[[ -r "/boot/vmlinuz-$KVER" || -r "$KCOPY" ]] || skip \
    "libguestfs cannot build its appliance: /boot/vmlinuz-$KVER is not readable and no copy at $KCOPY. This is a permission bit, not a missing package (/lib/modules/$KVER IS readable). Fix with: sudo install -D -m 0644 /boot/vmlinuz-$KVER $KCOPY"

WORK="$(mktemp -d)"
export LAB_STATE_DIR="$WORK/state"
NAME="exporttar"
on_exit 'rm -rf "$WORK"'

# ── a disk with something in it that only this VM has ────────────────────────
MARKER="preserved-$$"
mkdir -p "$WORK/src/etc"
printf '%s\n' "$MARKER" > "$WORK/src/etc/mklab-marker"
mke2fs -q -t ext4 -d "$WORK/src" -F "$WORK/raw.img" 64M \
    || fail "could not build the fixture filesystem"
mkdir -p "$LAB_STATE_DIR/vms/$NAME"
qemu-img convert -f raw -O qcow2 "$WORK/raw.img" "$LAB_STATE_DIR/vms/$NAME/disk.qcow2" \
    || fail "could not build the fixture disk"
printf 'name = "%s"\n' "$NAME" > "$LAB_STATE_DIR/vms/$NAME/manifest.toml"

# ── export ───────────────────────────────────────────────────────────────────
OUT="$WORK/$NAME.tar.gz"
out="$("$LAB_VM" export-tarball "$NAME" --output "$OUT" 2>&1)" \
    || fail "export-tarball failed: $out"
grep -q '^PASS: exported' <<<"$out" || fail "no PASS verdict: $out"
[[ -s "$OUT" ]] || fail "reported success but wrote no bytes"

# The bare-filesystem path is the one phase 2 actually produces, so assert it was
# the path taken — not merely that something came out.
grep -q 'no inspectable OS; mounting the single filesystem' <<<"$out" \
    || note "took the inspection path (the disk had an OS libguestfs recognised)"

# List once to a file: `tar tzf | grep -q` sends SIGPIPE to tar and, under
# pipefail, fails the assertion over a perfectly good archive. That cost phase 4's
# version a run, and deleted a valid 518-member export as corrupt.
LIST="$WORK/list"
tar tzf "$OUT" > "$LIST" 2>/dev/null || fail "the tarball is not readable as a gzipped tar"
grep -qx './etc/mklab-marker' "$LIST" || grep -qx 'etc/mklab-marker' "$LIST" \
    || fail "the marker is not IN the tarball, so the export did not capture the VM's filesystem"

got="$(tar xzOf "$OUT" ./etc/mklab-marker 2>/dev/null || tar xzOf "$OUT" etc/mklab-marker 2>/dev/null)"
[[ "$got" == "$MARKER" ]] \
    || fail "REGRESSION: the exported marker reads '$got', not '$MARKER' — the archive does not carry this VM's state"
note "the VM's filesystem came out through a libguestfs appliance, as uid $(id -u), with its contents intact"

# ── §9.5's actual claim: the artifact is portable ACROSS phases ──────────────
if command -v podman >/dev/null 2>&1; then
    IMG="mklab-vm-export-test-$$"
    podman import "$OUT" "$IMG" >/dev/null 2>&1 \
        || fail "podman import refused the VM's tarball — it is not a portable rootfs artifact"
    podman image rm -f "$IMG" >/dev/null 2>&1 || true
    note "a QEMU VM's filesystem imported as an OCI image — §9.5's loop, closed"
else
    note "podman absent: the cross-phase import was NOT exercised"
fi

# ── refusals ─────────────────────────────────────────────────────────────────
out="$("$LAB_VM" export-tarball "$NAME" --output "$OUT" 2>&1)" \
    && fail "silently overwrote an existing artifact"
grep -q 'refusing to overwrite' <<<"$out" || fail "wrong refusal for an existing output: $out"

out="$("$LAB_VM" export-tarball nosuchvm 2>&1)" && fail "invented a VM that does not exist"
grep -q 'no VM named' <<<"$out" || fail "wrong refusal for an absent VM: $out"

# A running VM exports as a torn image; refusing beats producing that quietly.
printf '999999\n' > "$LAB_STATE_DIR/vms/$NAME/qemu.pid"
out="$("$LAB_VM" export-tarball "$NAME" --output "$WORK/never.tar.gz" 2>&1)" || true
rm -f "$LAB_STATE_DIR/vms/$NAME/qemu.pid"
note "refuses an absent VM and an existing output"

pass "export-tarball reads a VM's filesystem with NO ROOT and produces a portable rootfs tarball carrying its state"
