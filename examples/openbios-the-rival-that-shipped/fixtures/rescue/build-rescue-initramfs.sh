#!/usr/bin/env bash
# build-rescue-initramfs.sh <MODE> <out.cpio> [busybox] — a REAL busybox initramfs
# whose init READS a config file, for UKI Spike 11's config rescue act.
#
# Unlike u-root (a Go init that reads no config, so nothing can be "broken"), this
# is a static-busybox initramfs with a genuine init path: /init is busybox (the
# init applet, chosen by argv basename — this kernel lacks CONFIG_BINFMT_SCRIPT, so
# a shell-script /init cannot be PID 1), /etc/inittab runs /etc/rc, and rc SOURCES
# /etc/rescue.conf and boots differently by what it reads:
#   MODE=run  -> "RESCUE-OK"  + a rescue shell
#   anything  -> "RESCUE-FAIL" + a genuine hang (the boot does not come up)
# `run` and `die` are both 3 bytes, so the whole `MODE=die\n`->`MODE=run\n` member
# is a SAME-LENGTH edit — exactly what dsl/cpio-edit.fth's cpio-patch does in place.
#
# UNCOMPRESSED newc on purpose: a real distro initrd is XZ/gzip and hundreds of MB
# (AlmaLinux's pxeboot initrd is 212 MB of XZ), which an in-firmware raw-newc editor
# cannot walk and this firmware cannot boot. busybox IS the real minimal-Linux init
# (dracut/mkinitramfs build on it); uncompressed keeps it firmware-editable.
#
# /dev/console (c 5,1) and /dev/null (c 1,3) are static nodes — PID 1's stdio needs
# /dev/console before devtmpfs is up, or its output goes nowhere (the kernel warns
# "unable to open an initial console"). They are made under fakeroot (no root/mknod
# privilege needed): fakeroot records the node type so cpio writes a device header.
set -euo pipefail
MODE="${1:?usage: build-rescue-initramfs.sh <MODE|cmdline> <out.cpio> [busybox]}"
OUT="${2:?usage: build-rescue-initramfs.sh <MODE|cmdline> <out.cpio> [busybox]}"
BB="${3:-$(command -v busybox || true)}"
[[ -n "$BB" && -f "$BB" ]] || { echo "no busybox found (arg 3 or PATH)" >&2; exit 2; }
file -L "$BB" | grep -q 'statically linked\|not a dynamic executable' \
    || { echo "busybox at $BB is not static — an initramfs busybox must be static" >&2; exit 3; }
command -v fakeroot >/dev/null || { echo "fakeroot not installed — needed to author /dev/console without root" >&2; exit 4; }
command -v cpio >/dev/null || { echo "cpio not installed" >&2; exit 5; }

DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/bin" "$DIR/etc" "$DIR/proc" "$DIR/sys" "$DIR/dev"
cp "$BB" "$DIR/bin/busybox"; chmod +x "$DIR/bin/busybox"
ln -sf bin/busybox "$DIR/init"          # basename "init" -> busybox init applet
cat > "$DIR/etc/inittab" <<'IT'
::sysinit:/bin/busybox mount -t proc proc /proc
::sysinit:/bin/busybox mount -t devtmpfs dev /dev
console::respawn:/bin/busybox sh /etc/rc
IT
if [ "$MODE" = cmdline ]; then
  # cmdline flavor: /init reads the KERNEL COMMAND LINE (/proc/cmdline) for a rescue
  # token — for the cmdline rescue act, where the UKI's .cmdline gates the boot.
  cat > "$DIR/etc/rc" <<'RC'
if /bin/busybox grep -q 'rescue_ok=1' /proc/cmdline; then
  /bin/busybox echo "RESCUE-OK: kernel cmdline has rescue_ok=1 -- reaching the rescue shell"
  exec /bin/busybox sh
else
  /bin/busybox echo "RESCUE-FAIL: kernel cmdline lacks rescue_ok=1 -- boot is blocked; add the param"
  /bin/busybox sleep 999999
fi
RC
else
  # config flavor: /init sources /etc/rescue.conf and boots by what it reads —
  # MODE=run reaches a shell, anything else hangs. `run`/`die` are both 3 bytes,
  # so MODE=die\n -> MODE=run\n is a SAME-LENGTH member edit for cpio-edit.fth.
  cat > "$DIR/etc/rc" <<'RC'
. /etc/rescue.conf
if [ "$MODE" = run ]; then
  /bin/busybox echo "RESCUE-OK: /etc/rescue.conf MODE=run -- reaching the rescue shell"
  exec /bin/busybox sh
else
  /bin/busybox echo "RESCUE-FAIL: /etc/rescue.conf MODE=$MODE is not runnable -- boot is blocked; fix the config"
  /bin/busybox sleep 999999
fi
RC
  printf 'MODE=%s\n' "$MODE" > "$DIR/etc/rescue.conf"
fi

# newc, uncompressed, member names without a leading ./ (so cpio-find matches
# "etc/rescue.conf"); device nodes authored under fakeroot.
( cd "$DIR" && fakeroot sh -c '
    rm -f dev/console dev/null
    mknod dev/console c 5 1
    mknod dev/null c 1 3
    find . -mindepth 1 -printf "%P\0" | cpio --null -H newc -o --quiet' ) > "$OUT"
echo "wrote $OUT ($(stat -c%s "$OUT") bytes, MODE=$MODE, $(cpio -it < "$OUT" 2>/dev/null | wc -l) members)"
