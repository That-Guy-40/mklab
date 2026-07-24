#!/bin/sh
# state-mount.sh — attach the package-mirror tree from NETWORK storage (NFS or
# iSCSI) for the RAM-resident mirror node. Called by /init BEFORE handing PID 1
# to systemd (or by an early systemd unit). The mirror tree is far too big to
# ship inside the RAM image, so it lives on a separate storage server/target and
# is mounted at boot; the image stays tiny and the OS stays ephemeral.
#
# THE LOAD-BEARING INVARIANT: this is GUARDED — it ALWAYS exits 0. /init runs
# `set -e`, so an unguarded failing mount (unreachable store, first boot before
# the target exists, an already-mounted tree) would panic PID 1. A degraded edge
# that serves an empty tree is strictly better than a kernel panic; the mount is
# retried on the next boot. (CLAUDE.md: "set -e panics PID 1".)
#
# Config via env (baked into the image or the kernel cmdline):
#   STATE_KIND = nfs | iscsi          (default nfs)
#   MIRROR_MNT = mount point          (default /srv/mirror)
#   NFS:   STATE_SRC = server:/export
#   iSCSI: ISCSI_PORTAL = ip:port  ISCSI_TARGET = iqn...  (LUN mounted by path)
set -u

MIRROR_MNT="${MIRROR_MNT:-/srv/mirror}"
STATE_KIND="${STATE_KIND:-nfs}"
log() { echo "state-mount: $*" >&2; }

mkdir -p "$MIRROR_MNT" 2>/dev/null || true

# Already mounted (e.g. a re-run)? Nothing to do — and do NOT fail.
if mountpoint -q "$MIRROR_MNT" 2>/dev/null; then
    log "$MIRROR_MNT already mounted; leaving it"
    exit 0
fi

mount_nfs() {
    : "${STATE_SRC:?NFS needs STATE_SRC=server:/export}"
    mount -t nfs4 -o vers=4.1,proto=tcp,ro,soft,timeo=50,retrans=2 \
        "$STATE_SRC" "$MIRROR_MNT"
}

mount_iscsi() {
    : "${ISCSI_PORTAL:?iSCSI needs ISCSI_PORTAL=ip:port}"
    : "${ISCSI_TARGET:?iSCSI needs ISCSI_TARGET=iqn...}"
    # discover → login → mount the LUN by stable /dev/disk/by-path symlink.
    iscsiadm -m discovery -t sendtargets -p "$ISCSI_PORTAL" || return 1
    iscsiadm -m node -T "$ISCSI_TARGET" -p "$ISCSI_PORTAL" --login || return 1
    # give udev a moment to create the by-path node, then mount read-only.
    dev="/dev/disk/by-path/ip-${ISCSI_PORTAL}-iscsi-${ISCSI_TARGET}-lun-0"
    i=0; while [ ! -e "$dev" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i+1)); done
    mount -o ro "$dev" "$MIRROR_MNT"
}

case "$STATE_KIND" in
    nfs)   mount_nfs   || log "WARN: NFS mount of the mirror failed — serving empty (retry next boot)" ;;
    iscsi) mount_iscsi || log "WARN: iSCSI attach of the mirror failed — serving empty (retry next boot)" ;;
    *)     log "WARN: unknown STATE_KIND='$STATE_KIND' — no mirror attached" ;;
esac

# ALWAYS succeed: /init must proceed to systemd no matter what happened above.
exit 0
