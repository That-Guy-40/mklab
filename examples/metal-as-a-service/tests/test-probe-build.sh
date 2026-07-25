#!/usr/bin/env bash
# Verdict: build-probe-initramfs.sh packages probe-init.sh into a bootable busybox
# initramfs — /init is the probe, busybox + its applets are present. The BUILD is
# host-safe (rootless cpio); only the boot is author-run. SKIPs without a static
# busybox.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need cpio gzip
trap 'cleanup_sandboxes' EXIT
maas_env

# find a static busybox the same way the builder does
BB=""
for c in "${MAAS_BUSYBOX:-}" /usr/bin/busybox "$LAB_DIR/../../micro-linux/out/x86_64/_install/bin/busybox"; do
    [[ -n "$c" && -x "$c" ]] && file "$c" 2>/dev/null | grep -q 'statically linked' && { BB="$c"; break; }
done
[[ -n "$BB" ]] || skip "no static busybox available to build the probe initramfs"

out="$SANDBOX/probe-initramfs.cpio.gz"
( MAAS_ARTIFACTS="$SANDBOX/art" "$LAB_DIR/build-probe-initramfs.sh" --out "$out" --busybox "$BB" ) \
    >/dev/null 2>&1 || fail "build-probe-initramfs.sh failed"
[[ -s "$out" ]] || fail "no initramfs produced at $out"
note "initramfs built ($(du -h "$out" | cut -f1)) ✓"

# unpack and assert /init is the probe + busybox is present
un="$SANDBOX/unpacked"; mkdir -p "$un"
( cd "$un" && zcat "$out" | cpio -idm --quiet ) || fail "could not unpack the initramfs"
[[ -f "$un/init" ]] || fail "REGRESSION: no /init in the initramfs (kernel would panic)"
head -1 "$un/init" | grep -q '^#!/bin/sh' || fail "/init is not a shell script"
grep -q 'MAAS inspection probe' "$un/init" || fail "/init is not the MAAS probe"
[[ -f "$un/bin/busybox" ]] || fail "no /bin/busybox in the initramfs"
[[ -L "$un/bin/sh" && -L "$un/bin/wget" ]] || fail "busybox applet symlinks (sh, wget) missing — /init tools won't resolve"
note "/init is the probe; busybox + sh/wget applets present ✓"

# the packaged /init still gathers facts (same logic the unit test proves) —
# smoke it in --emit mode against fixture /proc so the SHIPPED copy is exercised
fix="$SANDBOX/procfix"; mkdir -p "$fix/class/net/eth0"
printf 'processor\t: 0\nprocessor\t: 1\n' > "$fix/cpuinfo"
printf 'MemTotal:        2048000 kB\n' > "$fix/meminfo"
printf 'aa:bb:cc:dd:ee:ff\n' > "$fix/class/net/eth0/address"
j="$(PROC_ROOT="$fix" SYS_ROOT="$fix" sh "$un/init" --emit)" || fail "packaged /init --emit failed"
grep -q '"cpus":2' <<<"$j" || fail "packaged /init emitted wrong facts: $j"
note "the SHIPPED /init gathers facts (cpus=2) ✓"

pass "probe initramfs builds: /init is the probe, busybox present, shipped /init gathers facts"
