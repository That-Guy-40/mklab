#!/usr/bin/env bash
# build-probe-initramfs.sh — package probe-init.sh into a bootable busybox
# initramfs for the MAAS inspection probe. Rootless: assembles a rootfs, symlinks
# the busybox applets, drops probe-init.sh as /init, and packs it with
# `find | cpio -H newc | gzip` (no mknod/root — the /init mounts devtmpfs to get
# /dev/console; the kernel's own console carries the early banners regardless).
#
#   build-probe-initramfs.sh [--out FILE] [--busybox PATH]
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
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)     OUT="$2"; shift 2 ;;
        --busybox) BUSYBOX="$2"; shift 2 ;;
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
while IFS= read -r applet; do
    [[ -n "$applet" ]] || continue
    ln -sf /bin/busybox "$work/bin/$applet"
done < <("$BUSYBOX" --list 2>/dev/null)

# /init = the probe (kernel execs /init directly; no inittab needed)
cp "$HERE/probe-init.sh" "$work/init"
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

size="$(du -h "$OUT" | cut -f1)"
echo "built probe initramfs: $OUT ($size)" >&2
echo "contents (should include ./init and ./bin/busybox):" >&2
zcat "$OUT" | cpio -t --quiet 2>/dev/null | grep -E '^(init|bin/busybox)$' | sed 's/^/  /' >&2
cat >&2 <<EOF

Next (author-run): serve it + a kernel over the PXE HTTP endpoint and boot a node:
  cp "$OUT" ~/netboot/initrd.gz          # the busybox-payload docroot (:8181)
  # kernel cmdline must carry:  maas.node=<name>  maas.md=http://<gw>:8282
  ./metadata-serve.sh --port 8282 &      # the facts sink (separate from :8181)
  ./maas-lab.sh inspect <node> --boot    # PXE-boots the probe, awaits facts, powers off
EOF
