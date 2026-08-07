#!/usr/bin/env bash
# make-vsock-rootfs.sh — add a vsock agent to slice 3's guest image, without root.
#
# THE GAP SLICE 5c ACTUALLY HAD. "Is vsock available?" sounds like a question about
# plumbing, and every plumbing answer was yes: /dev/vhost-vsock is root:kvm 0660 with uid
# 1000 in kvm, the host modules are loaded, QEMU has vhost-vsock-device on the virtio-bus
# (so it works on -M microvm), and the lab kernel has CONFIG_VSOCKETS/VIRTIO_VSOCK built
# in — which matters because Firecracker boots with no initramfs and a modular driver
# would be one that never loads. The gap was USERSPACE: `strings api1.ext4 | grep -ci
# vsock` was 0. The guest is busybox+musl, and busybox `nc` has no AF_VSOCK. The kernel
# could, and nothing in the image could ask it to.
#
# NO LOOP MOUNT, NO SUDO. `mount -o loop` and `mknod` are unavailable to the agent that
# built this lab (blocked even --privileged), and needing root to add one file to an image
# would put this step behind the same gate as everything else in slice 3. `debugfs -w`
# writes into an ext4 without mounting it, which is the same family of trick as
# `mke2fs -d` in export-rootfs — the whole reason that path was chosen (plan §6).
#
# THE SOURCE IMAGE IS NEVER TOUCHED. It is copied first, and the copy is fsck'd: a guest
# that was killed mid-run (which is how every break-pass image ends) leaves a dirty bitmap
# that debugfs refuses to open — "Inode bitmap checksum does not match bitmap". Repairing
# the ORIGINAL would quietly rewrite the artifact other tests boot.
#
# Usage: make-vsock-rootfs.sh [--in BASE.ext4] [--out OUT.ext4] [--port 1234]
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STATE="${MC_STATE_DIR:-$HOME/.local/state/lab-create/micro-cloud-s3}"
IN="$STATE/api1.ext4"
OUT="$STATE/vsock.ext4"
PORT=1234

_log()  { printf '[%s] %s\n' "$1" "${*:2}" >&2; }
info()  { _log info "$@"; }
die()   { _log error "$@"; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --in)   shift; IN="${1:?--in needs a path}";   shift ;;
        --out)  shift; OUT="${1:?--out needs a path}"; shift ;;
        --port) shift; PORT="${1:?--port needs a number}"; shift ;;
        -h|--help) sed -n '2,20p' "$0" >&2; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

for c in musl-gcc debugfs e2fsck; do
    command -v "$c" >/dev/null 2>&1 \
        || die "missing '$c'. musl-gcc (musl-tools) builds a static agent the busybox+musl guest can exec; debugfs/e2fsck (e2fsprogs) edit the image without a loop mount"
done
[[ -r "$IN" ]] || die "no source rootfs at $IN — slice 3's image is what this adds an agent to (override with --in)"

WORK="$(mktemp -d)"; trap 'rm -rf -- "$WORK"' EXIT

# ── 1. build the agent, statically ─────────────────────────────────────────
# Static because the guest is musl-based busybox with no toolchain and no package
# manager worth using offline: a dynamically linked agent is one more thing that can be
# subtly absent, and "the binary is there but will not exec" is a bad failure to debug
# through a serial console.
AGENT="$WORK/mc-vsock-agent"
if [[ -r /usr/include/linux/vm_sockets.h ]]; then
    # -idirafter, not -I: a plain -I/usr/include puts glibc's headers AHEAD of musl's.
    musl-gcc -static -Os -Wall -Wextra -idirafter /usr/include \
        -o "$AGENT" "$HERE/vsock-agent.c" || die "could not build the vsock agent"
    built_with="the kernel uapi header"
else
    musl-gcc -static -Os -Wall -Wextra -DMC_VSOCK_NO_UAPI \
        -o "$AGENT" "$HERE/vsock-agent.c" || die "could not build the vsock agent (no-uapi fallback)"
    built_with="the restated UAPI fallback (no linux-libc-dev on this host)"
fi
info "agent: $(stat -c %s "$AGENT") bytes, static, built with $built_with"

# The fallback's struct sockaddr_vm is hand-written, and a hand-written ABI that has
# drifted would produce an agent that binds the wrong thing and fails in the guest, far
# from here. When both inputs are available, compile it BOTH ways and compare the bytes.
# (Measured 2026-08-07: identical. That is the assertion, not the assumption.)
if [[ -r /usr/include/linux/vm_sockets.h ]]; then
    musl-gcc -static -Os -DMC_VSOCK_NO_UAPI -o "$WORK/agent-nouapi" "$HERE/vsock-agent.c" 2>/dev/null || true
    if [[ -f "$WORK/agent-nouapi" ]]; then
        if cmp -s "$AGENT" "$WORK/agent-nouapi"; then
            info "  the no-uapi fallback compiles to byte-identical code — its struct matches the header"
        else
            die "vsock-agent.c's MC_VSOCK_NO_UAPI fallback no longer matches <linux/vm_sockets.h>: the two builds differ.
  Someone editing the fallback (or a kernel-header change) has made it possible to build an
  agent whose sockaddr_vm layout is wrong. It would still compile, still run, and bind the
  wrong address inside the guest. Fix the fallback before shipping an image built from it."
        fi
    fi
fi

# ── 2. copy + repair, never the original ───────────────────────────────────
info "copying $IN -> $OUT"
cp -f -- "$IN" "$OUT" || die "could not copy the source rootfs"
# e2fsck exits 1 for "errors corrected", which is the NORMAL case here and not a failure.
# 2 (reboot needed) and 4 (uncorrected) are.
set +e; e2fsck -fy "$OUT" > "$WORK/fsck.log" 2>&1; fsck_rc=$?; set -e
case $fsck_rc in
    0) info "image was already clean" ;;
    1) info "image had a dirty bitmap (a guest killed mid-run); repaired on the COPY" ;;
    *) cat "$WORK/fsck.log" >&2
       die "e2fsck could not repair the copy (rc=$fsck_rc) — refusing to write an agent into a filesystem that is not sound" ;;
esac

# ── 3. write the agent and its launcher in ─────────────────────────────────
# THE AGENT MUST NOT BE A `respawn` ENTRY, and this is the one non-obvious part of the
# file. BusyBox init runs every `sysinit` action to completion, in order, and only then
# starts the `respawn` ones. mc-probe.sh is a sysinit action that blocks for up to ~60 s
# (udhcpc retries, then a 40 s ping loop for a peer). A `respawn` agent would therefore
# not exist for the first minute of the guest's life — and with no tap attached, which is
# the whole point of this slice, mc-probe.sh takes its SLOWEST path. The channel that is
# supposed to be independent of the fabric would have been the one waiting on it.
#
# So it goes in as a sysinit action that backgrounds itself, ahead of mc-probe.sh, with a
# respawn loop of its own: a crashed agent comes back, and the restart is visible on the
# console instead of being a silence. The console ordering is asserted in the test, not
# assumed here — this comment is a claim about busybox's behaviour and the LISTENING line
# arriving before SLICE3-BEGIN is the measurement of it.
#
# The second background line is a LINK TIMELINE, opt-in with `mc_link=1` on the kernel
# command line. The chaos matrix needs to prove that severing the guest's network actually
# LANDED, and mc-probe.sh's own WATCH mode cannot serve: it runs only after a 40-iteration
# peer-ping loop, so the first WATCH line arrives ~80 s in. Worse, depending on it would
# couple the matrix to mc-probe.sh's internals — a mechanism dependency, when what is wanted
# is the outcome (did the guest lose carrier?). Measured: without such a timeline the
# network row graded ABSORBED even when the injector was replaced by a no-op, because vsock
# answers either way. It was passing without its own fault.
cat > "$WORK/inittab" <<INITTAB
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/sh -c 'while :; do /sbin/mc-vsock-agent $PORT; echo "MC-VSOCK-AGENT EXITED rc=\$? — restarting"; sleep 1; done &'
::sysinit:/bin/sh -c 'case " \$(cat /proc/cmdline) " in *" mc_link=1 "*) while :; do echo "MC-LINK carrier=\$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo NA) operstate=\$(cat /sys/class/net/eth0/operstate 2>/dev/null || echo NA)"; sleep 2; done & ;; esac'
::sysinit:/mc-probe.sh
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100
::ctrlaltdel:/sbin/reboot
INITTAB

dbg() { debugfs -w -R "$1" "$OUT" 2>&1; }
out="$(dbg "rm /sbin/mc-vsock-agent")"; :   # absent on a first run; not an error
out="$(dbg "write $AGENT sbin/mc-vsock-agent")"
grep -q "Allocated inode" <<<"$out" \
    || die "debugfs did not write the agent into $OUT: $out"
dbg "sif /sbin/mc-vsock-agent mode 0100755" >/dev/null
out="$(dbg "rm /etc/inittab")"; :
out="$(dbg "write $WORK/inittab etc/inittab")"
grep -q "Allocated inode" <<<"$out" \
    || die "debugfs did not write the new inittab into $OUT: $out"
dbg "sif /etc/inittab mode 0100644" >/dev/null

# ── 4. read it back OUT of the image, and compare bytes ────────────────────
# "debugfs said Allocated inode" is the mechanism; "the image contains the agent I built"
# is the outcome. They are not the same claim — a wrong path, a truncated write or a
# silently-failed chmod all leave the first one true.
debugfs -R "dump /sbin/mc-vsock-agent $WORK/readback" "$OUT" >/dev/null 2>&1 \
    || die "could not read the agent back out of $OUT"
cmp -s "$AGENT" "$WORK/readback" \
    || die "the agent read back out of $OUT differs from the one just built — the write did not land intact"
mode="$(debugfs -R "stat /sbin/mc-vsock-agent" "$OUT" 2>/dev/null | sed -n 's/.*Mode: *0*\([0-7]*\).*/\1/p' | head -1)"
[[ "$mode" == "755" ]] \
    || die "the agent is in $OUT with mode '${mode:-<unreadable>}', not 755 — busybox init would fail to exec it and the guest would report nothing at all"
readback_inittab="$(debugfs -R "cat /etc/inittab" "$OUT" 2>/dev/null)"
grep -q "mc-vsock-agent $PORT" <<<"$readback_inittab" \
    || die "the new inittab is not in $OUT — the agent would be present and never started, which looks exactly like a broken transport"

e2fsck -fn "$OUT" >/dev/null 2>&1 \
    || die "the image is not clean after the edits — refusing to hand a guest a filesystem debugfs left inconsistent"

info "wrote $OUT"
info "  /sbin/mc-vsock-agent  $(stat -c %s "$AGENT") bytes, mode 755, verified by read-back"
info "  /etc/inittab          respawns it on port $PORT, BEFORE mc-probe.sh's 40s network wait"
info ""
info "next: examples/micro-cloud/tests/test-vsock-both-engines.sh (no root, no fabric)"
