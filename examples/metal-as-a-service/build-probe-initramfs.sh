#!/usr/bin/env bash
# build-probe-initramfs.sh — package probe-init.sh into a bootable busybox
# initramfs for the MAAS inspection probe. Rootless: assembles a rootfs, symlinks
# the busybox applets, drops probe-init.sh as /init, and packs it with
# `find | cpio -H newc | gzip` (no mknod/root — the /init mounts devtmpfs to get
# /dev/console; the kernel's own console carries the early banners regardless).
#
#   build-probe-initramfs.sh [--out FILE] [--busybox PATH] [--shell]
#
# --shell packs the SAME rootfs with an /init that just gives you a shell instead of
# the fact-poster. That is the `busybox-netboot` entry in ramdisk-catalog.toml — the
# smallest thing in the repo that is still a login, and a payload for
# `deploy --driver ramdisk`. Same packer, different /init: the alternative was a
# second near-identical script.
#
# The image is diskless + stateless: it boots over PXE (bootdev=pxe), the probe
# POSTs facts to the metadata service, and it powers off. Pair it with a kernel and
# serve both over the PXE HTTP endpoint (see virtualbmc-ipmi-lab/setup-pxe-net.sh,
# which serves `kernel` + `initrd.gz` off :8181) — kernel cmdline must carry
#     maas.node=<name>  maas.md=http://<gw>:8282
# so the probe knows its identity + where to report. Building is host-safe; BOOTING
# is author-run (needs the PXE net + a node).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OUT="${MAAS_ARTIFACTS:-$HOME/.cache/lab-create/maas}/probe-initramfs.cpio.gz"
BUSYBOX="${MAAS_BUSYBOX:-}"
MODE=probe
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)     OUT="$2"; shift 2 ;;
        --busybox) BUSYBOX="$2"; shift 2 ;;
        --shell)   MODE=shell; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "build-probe-initramfs: unknown option $1" >&2; exit 1 ;;
    esac
done
die() { echo "build-probe-initramfs: $*" >&2; exit 1; }

# Locate a STATIC busybox (a dynamic one can't run in an initramfs with no libs).
if [[ -z "$BUSYBOX" ]]; then
    for c in /usr/bin/busybox "$HERE/../../micro-linux/out/x86_64/_install/bin/busybox"; do
        [[ -x "$c" ]] && { BUSYBOX="$c"; break; }
    done
fi
[[ -n "$BUSYBOX" && -x "$BUSYBOX" ]] || die "no busybox found — install busybox-static or pass --busybox PATH"
file "$BUSYBOX" | grep -q 'statically linked' || die "busybox at $BUSYBOX is not static — an initramfs needs a static one"
command -v cpio >/dev/null || die "cpio required"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work"/{bin,sbin,proc,sys,dev,usr/share/udhcpc}

cp "$BUSYBOX" "$work/bin/busybox"
chmod +x "$work/bin/busybox"
# symlink every applet this busybox provides, so /init's tools (sh, mount, sed,
# awk, wget, nc, udhcpc, ifconfig, poweroff, …) all resolve.
#
# SKIP `busybox` ITSELF. It appears in `--list` like any other applet, and linking it
# makes /bin/busybox a symlink to /bin/busybox — a self-referential loop that REPLACES
# the binary we just copied. Every applet then resolves to nothing, the kernel execs
# /init, follows /bin/sh -> /bin/busybox -> itself, and panics with
#   Failed to execute /init (error -40)      [-40 = ELOOP]
#   Kernel panic - not syncing: No working init found.
# This shipped: the probe had never once booted, and the build's own check passed
# because it asked whether `bin/busybox` EXISTS in the cpio — which a symlink to
# nowhere does.
while IFS= read -r applet; do
    [[ -n "$applet" && "$applet" != busybox ]] || continue
    ln -sf /bin/busybox "$work/bin/$applet"
done < <("$BUSYBOX" --list 2>/dev/null)
# Prove it, here, before anything packs it: the binary must still be a binary.
[[ -f "$work/bin/busybox" && ! -L "$work/bin/busybox" ]] \
    || die "internal: bin/busybox is a symlink, not the binary — the applet loop clobbered it"
"$work/bin/busybox" true 2>/dev/null \
    || die "internal: the staged bin/busybox does not execute — the initramfs would panic at boot"

# /init (the kernel execs it directly; no inittab needed)
if [[ "$MODE" == shell ]]; then
    # the ramdisk-catalog `busybox-netboot` payload: boot straight to a shell. The
    # prompt IS the health signal, so it must reach the console the driver watches.
    cat > "$work/init" <<'EOS'
#!/bin/busybox sh
/bin/busybox mount -t proc     none /proc     2>/dev/null
/bin/busybox mount -t sysfs    none /sys      2>/dev/null
/bin/busybox mount -t devtmpfs none /dev      2>/dev/null
exec /bin/busybox sh
EOS
else
    cp "$HERE/probe-init.sh" "$work/init"
fi
chmod +x "$work/init"

# udhcpc lease applier — reuse micro-linux's if present, else a minimal one
if [[ -f "$HERE/../../micro-linux/udhcpc.script" ]]; then
    cp "$HERE/../../micro-linux/udhcpc.script" "$work/usr/share/udhcpc/default.script"
else
    cat > "$work/usr/share/udhcpc/default.script" <<'EOS'
#!/bin/sh
# minimal udhcpc handler: apply IP + default route on bound/renew
[ -n "$1" ] || exit 1
case "$1" in
  bound|renew)
    ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}"
    [ -n "$router" ] && route add default gw "$router" dev "$interface" ;;
esac
exit 0
EOS
fi
chmod +x "$work/usr/share/udhcpc/default.script"

mkdir -p "$(dirname "$OUT")"
( cd "$work" && find . -print0 | cpio --null -o -H newc --quiet | gzip -9 ) > "$OUT" \
    || die "cpio/gzip failed"

# Unpack what we just packed and RUN the shell out of it. Listing the archive only
# proves the paths are present, which is what let a self-symlinked busybox — an
# initramfs that panics on every boot — pass this check and ship.
verify="$work.verify"; mkdir -p "$verify"
if zcat "$OUT" | ( cd "$verify" && cpio -idm --quiet 2>/dev/null ); then
    [[ -f "$verify/init" ]] || die "the packed initramfs has no /init"
    [[ -f "$verify/bin/busybox" && ! -L "$verify/bin/busybox" ]] \
        || die "the packed /bin/busybox is not a real file — the initramfs would panic with 'No working init found'"
    "$verify/bin/busybox" true 2>/dev/null \
        || die "the packed /bin/busybox does not execute — this initramfs cannot boot"
    [[ -L "$verify/bin/sh" ]] || die "the packed /bin/sh is missing — /init's shebang would not resolve"
    "$verify/bin/sh" -c 'exit 0' 2>/dev/null \
        || die "the packed /bin/sh does not resolve to a working shell (a symlink loop?)"
else
    die "could not unpack the initramfs we just wrote — refusing to call it built"
fi
rm -rf "$verify"

size="$(du -h "$OUT" | cut -f1)"
echo "built ${MODE} initramfs: $OUT ($size)" >&2
echo "verified: /init present, /bin/busybox is a real static binary that RUNS, /bin/sh resolves" >&2
cat >&2 <<EOF

Next (author-run): serve it + a kernel over the PXE HTTP endpoint and boot a node:
  cp "$OUT" ~/netboot/initrd.gz          # the busybox-payload docroot (:8181)
  # kernel cmdline must carry:  maas.node=<name>  maas.md=http://<gw>:8282
  ./metadata-serve.sh --port 8282 &      # the facts sink (separate from :8181)
  ./maas-lab.sh inspect <node> --boot    # PXE-boots the probe, awaits facts, powers off
EOF
